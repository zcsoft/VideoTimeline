//
//  VideoTimelineView.swift
//  VideoTimeline
//

import UIKit
import CoreMedia
import Combine
import AVFoundation

/// 协议：当时间线加载完成后通知委托
protocol ZCVideoTimelineViewDelegate {
    func timelineReady()
}

/// 视频时间轴视图，用于展示视频缩略图、播放头和时间标签
class ZCVideoTimelineView: UIView, UIScrollViewDelegate {
    
    // MARK: - 属性
    
    /// 缩略图生成器（自定义类，根据视频 URL 请求缩略图）
    private var thumbGenerator: ZCThumbnailGenerator?
    
    /// Combine 取消订阅集合，用于管理订阅生命周期
    private var cancellables = Set<AnyCancellable>()
    
    /// 缩略图高度（固定）
    private let thumbHight: CGFloat = 40
    
    /// 缩略图时间间隔（初始值为 1 秒）
    private var thumbIntervalSeconds: Double = 1
    
    /// 最小缩略图数量（如果生成的缩略图数小于此值则调整间隔）
    private var minThumbCount: Int = 20
    
    /// 最大缩略图数量（如果生成的缩略图数大于此值则调整间隔）
    private var maxThumbCount: Int = 100
    
    /// 滚动视图左右内边距（初始值为 0，后续根据视图宽度计算）
    private var scrollPadding = 0.0
        
    /// 标记是否已经加载完所有缩略图
    private var thumbLoaded = false
    
    /// 标记时间标签是否已经添加（避免重复添加）
    private var timeLabelsAdded = false
    
    /// 当前拖动的 seek 时间（使用 Combine 进行处理）
    private var seekTime = CurrentValueSubject<CMTime, Never>(.zero)
    
    /// 上一次 seek 的时间，用于控制 seek 频率
    private var lastSeekTime: CMTime?
    
    /// 标记用户是否正在拖动滚动视图
    private var isDragging = false
    
    /// 缩略图的Y轴位置
    var thumbImageViewY: CGFloat = 28
    
    /// 代理，用于通知时间轴加载完成
    var delegate: ZCVideoTimelineViewDelegate?
    
    /// 视频播放器接口（自定义协议），设置后会触发配置缩略图滚动视图
    var player: ZCVideoPlayerIntf? {
        didSet {
            configureThumbScrollView()
        }
    }
    
    // MARK: - 子视图
    
    /// 缩略图滚动视图，用于展示视频每个时间点的缩略图
    private lazy var thumbScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = self
        return scrollView
    }()
    
    /// 播放头视图，标识当前播放位置
    private let playheadView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 2
        // 自定义颜色（支持十六进制颜色扩展方法）
        view.backgroundColor = UIColor(hex: "#C4FFE7FF")
        return view
    }()
    
    /// 显示当前播放时间的标签
    private let timeView: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.textColor = .white
        return label
    }()
    
    // MARK: - 初始化
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI 布局
    
    /// 初始化并添加各个子视图，并设置约束
    private func setupViews() {
        // 设置背景色
        backgroundColor = UIColor(hex: "#F4F4F4FF")
        
        // 添加缩略图滚动视图
        addSubview(thumbScrollView)
        // 使用自定义约束方法（假设 constraints 方法封装了 Auto Layout 逻辑）
        thumbScrollView.constraints(leading: leadingAnchor,
                                    top: topAnchor,
                                    trailing: trailingAnchor,
                                    paddingTop: 0,
                                    height: thumbHight + thumbImageViewY)
        
        // 添加播放头视图
        addSubview(playheadView)
        playheadView.constraints(top: thumbScrollView.topAnchor,
                                 paddingTop: -10 + thumbImageViewY,
                                      width: 4,
                                     height: thumbHight + 20,
                                    centerX: centerXAnchor)
        
        // 添加时间显示视图
        addSubview(timeView)
        timeView.constraints(top: playheadView.bottomAnchor,
                             paddingTop: 8,
                             width: 120,
                             centerX: centerXAnchor)
        timeView.text = "00:00"
        timeView.isHidden = true
    }
    
    // MARK: - 缩略图加载与配置
    
    /// 加载视频缩略图，并根据视频尺寸和时长调整显示
    private func loadThumbImages() {
        // 获取视频 URL
        guard let videoURL = player?.url else { return }
        
        // 计算缩略图宽度：根据视频实际尺寸与 thumbHight 保持比例
        var thumbWidth: CGFloat
        let asset = AVAsset(url: videoURL)
        if let track = asset.tracks(withMediaType: .video).first {
            // 应用旋转变换，获取实际视频尺寸
            let transformedSize = track.naturalSize.applying(track.preferredTransform)
            let videoSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
            thumbWidth = (thumbHight / videoSize.height) * videoSize.width
        } else {
            // 默认宽高比为 4:3
            thumbWidth = thumbHight * (4/3)
            // 限制最小宽度
            if thumbWidth < 22 { thumbWidth = 22 }
        }
        let thumbImageSize = CGSize(width: thumbWidth, height: thumbHight)
        
        // 根据视频时长调整缩略图生成的间隔，确保生成缩略图数量在 minThumbCount ~ maxThumbCount 之间
        let videoDuration = asset.duration.seconds
        if Int(videoDuration / thumbIntervalSeconds) < minThumbCount {
            thumbIntervalSeconds = videoDuration / Double(minThumbCount)
        }
        if Int(videoDuration / thumbIntervalSeconds) > maxThumbCount {
            thumbIntervalSeconds = videoDuration / Double(maxThumbCount)
        }
        
        // 初始化缩略图生成器，并请求生成缩略图
        thumbGenerator = ZCThumbnailGenerator(url: videoURL)
        thumbGenerator?.requestThumbnails(intervalSeconds: thumbIntervalSeconds,
                                          maxSize: thumbImageSize) { [weak self] image, index, totalCount in
            // 切换到主线程处理 UI 更新
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                // 第一次回调时，根据总数设置滚动视图的 contentSize 与内边距
                if index == 0 {
                    let scrollWidth = CGFloat(totalCount) * thumbWidth
                    let rightPadding = scrollWidth <= self.scrollPadding ? 0.0 : self.scrollPadding
                    
                    self.thumbScrollView.contentInset = UIEdgeInsets(top: 0,
                                                                     left: self.scrollPadding,
                                                                     bottom: 0,
                                                                     right: rightPadding)
                    self.thumbScrollView.contentSize = CGSize(width: scrollWidth, height: self.thumbHight)
                    
                    // 添加顶部时间标签（仅添加一次）
                    if !self.timeLabelsAdded {
                        self.addTimeLabels()
                    }
                }
                
                // 如果生成了缩略图 image，则创建 UIImageView 显示缩略图
                if let cgImage = image {
                    let thumbImageView = UIImageView(image: UIImage(cgImage: cgImage))
                    thumbImageView.contentMode = .scaleAspectFill
                    thumbImageView.frame.size = thumbImageSize
                    // 根据索引确定缩略图在滚动视图中的位置
                    thumbImageView.frame.origin = CGPoint(x: CGFloat(index) * thumbWidth, y: self.thumbImageViewY)
                    thumbImageView.alpha = 1
                    
                    // 对首尾缩略图做圆角处理
                    if index == 0 {
                        thumbImageView.layer.masksToBounds = true
                        thumbImageView.layer.cornerRadius = 6
                        thumbImageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                    } else if index == totalCount - 1 {
                        thumbImageView.layer.masksToBounds = true
                        thumbImageView.layer.cornerRadius = 6
                        thumbImageView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                    }
                    
                    self.thumbScrollView.addSubview(thumbImageView)
                    
                    // 动画效果（淡入）
                    UIView.animate(withDuration: 0.3) {
                        thumbImageView.alpha = 1
                    }
                }
                
                // 最后一次回调时，标记加载完成，开始观察播放器状态，并通知委托
                if index == totalCount - 1 {
                    self.thumbLoaded = true
                    self.observePlayer()
                    self.delegate?.timelineReady()
                }
            }
        }
    }
    
    // MARK: - 添加顶部时间标签
    
    /// 在 thumbScrollView 的顶部位置，根据内容宽度和视频总时长，
    /// 每两个标签之间保留 36 像素间隔（标签宽 30，步长 66），
    /// 并在每两个标签之间添加一个 “·” 分隔符。
    private func addTimeLabels() {
        // 确保视频时长有效
        guard let videoDurationSeconds = player?.duration?.seconds, videoDurationSeconds > 0 else { return }
        let contentWidth = thumbScrollView.contentSize.width

        let gap: CGFloat = 36        // 两个标签之间的间隔
        let labelWidth: CGFloat = 30   // 每个标签的宽度
        let step = labelWidth + gap    // 标签之间的水平步长（即标签的宽度加上间隔）

        // 根据 contentWidth 和步长计算可放置的标签数量
        let numberOfLabels = Int(contentWidth / step) + 1

        for i in 0..<numberOfLabels {
            // 标签的 x 坐标：每个标签左边缘的位置为 i * step
            let labelX = CGFloat(i) * step
            let labelFrame = CGRect(x: labelX, y: 0, width: labelWidth, height: 14)
            let timeLabel = UILabel(frame: labelFrame)
            timeLabel.font = UIFont.systemFont(ofSize: 10)
            timeLabel.textAlignment = .center
            timeLabel.textColor = UIColor(hex: "#C3C3C3FF")
            timeLabel.backgroundColor = .clear
            
            // 使用标签中心位置来计算对应的时间
            let labelCenter = labelX + labelWidth / 2
            let timeInSeconds = (labelCenter / contentWidth) * CGFloat(videoDurationSeconds)
            timeLabel.text = formatTime(timeInSeconds: Double(timeInSeconds))
            
            thumbScrollView.addSubview(timeLabel)
            thumbScrollView.bringSubviewToFront(timeLabel)
            
            // 每两个标签之间添加一个“·”分隔符（最后一个标签后不添加）
            if i < numberOfLabels - 1 {
                // 分隔符的中心位置为当前标签右边缘 + gap/2
                let dotCenterX = labelX + labelWidth + gap / 2
                // 分隔符宽度设为 10，高度与标签一致
                let dotFrame = CGRect(x: dotCenterX - 5, y: 0, width: 10, height: 14)
                let dotLabel = UILabel(frame: dotFrame)
                dotLabel.font = UIFont.systemFont(ofSize: 10)
                dotLabel.textAlignment = .center
                dotLabel.textColor = UIColor(hex: "#C3C3C3FF")
                dotLabel.backgroundColor = .clear
                dotLabel.text = "·"
                
                thumbScrollView.addSubview(dotLabel)
                thumbScrollView.bringSubviewToFront(dotLabel)
            }
        }
        
        timeLabelsAdded = true
    }

    /// 辅助方法：将秒数格式化为 "mm:ss" 格式的字符串
    private func formatTime(timeInSeconds: Double) -> String {
        let minutes = Int(timeInSeconds) / 60
        let seconds = Int(timeInSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// 根据视图宽度配置滚动视图，并加载缩略图
    private func configureThumbScrollView() {
        // 设置左右滚动内边距为视图宽度的一半
        scrollPadding = frame.width / 2
        loadThumbImages()
    }
    
    // MARK: - 播放器观察
    
    /// 观察播放器的当前时间和状态，实现时间轴与视频播放的联动
    private func observePlayer() {
        // 获取视频时长，确保有效
        guard let videoDuration = player?.duration?.seconds, videoDuration > 0 else { return }
        
        // 计算每秒对应滚动视图的偏移量
        let scrollWidth = thumbScrollView.contentSize.width
        let moveStep = scrollWidth / videoDuration
        
        // 订阅播放器当前播放时间的变化
        player?.currentTimeObservable
            .sink { [weak self] playingTime in
                guard let self = self else { return }
                
                // 更新中间时间标签（格式转换方法 toHHMMSS 需自定义扩展）
                self.timeView.text = "\(Int(playingTime.seconds).toHHMMSS)"
                
                // 如果播放器正在播放，则自动更新滚动视图的偏移，使播放头始终位于中间
                if self.player?.status == .playing {
                    let scrollOffset = -self.scrollPadding + playingTime.seconds * moveStep
                    self.thumbScrollView.setContentOffset(CGPoint(x: scrollOffset, y: 0), animated: true)
                }
            }
            .store(in: &cancellables)
        
        // 订阅播放器状态变化
        player?.statusObservable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                
                // 如果播放状态为 playing，取消拖拽状态，恢复自动滚动
                if status == .playing {
                    self.isDragging = false
                }
                
                // 当播放结束后，将视频和滚动视图回滚到起始位置
                if status == .finished {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.player?.seek(to: .zero, completion: nil)
                        self.thumbScrollView.setContentOffset(CGPoint(x: -self.scrollPadding, y: 0), animated: true)
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - UIScrollViewDelegate
    
    /// 开始拖拽时调用，暂停视频播放
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isDragging = true
        player?.pause()
    }
    
    /// 拖拽滚动时调用，根据滚动位置计算对应的播放时间，并执行 seek 操作
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 如果没有加载完缩略图或不是用户拖拽状态，则直接返回
        guard let videoDuration = player?.duration, thumbLoaded, isDragging else { return }
        
        let scrollWidth = thumbScrollView.contentSize.width
        // 计算播放头在滚动视图中的位置：当前偏移量加上左右内边距
        var playHeadPos = thumbScrollView.contentOffset.x + scrollPadding
        
        // 限制 playHeadPos 在有效范围内
        playHeadPos = min(max(playHeadPos, 0), scrollWidth)
        
        // 根据滚动比例计算对应的播放时间
        let ratio = playHeadPos / scrollWidth
        let timeValue = Int64(Double(videoDuration.value) * ratio)
        let time = CMTimeMake(value: timeValue, timescale: videoDuration.timescale)
        
        // 设置最小 seek 间隔，防止频繁调用 seek 操作
        let minSeekInterval = 0.3
        if let lastTime = lastSeekTime, abs(time.seconds - lastTime.seconds) < minSeekInterval {
            return
        }
        lastSeekTime = time
        
        // 执行 seek 操作，更新视频播放位置
        player?.seek(to: time, completion: nil)
    }
}
