//
//  VideoPlayer.swift
//  VideoTimeline
//
//

import Foundation
import AVFoundation
import Combine

/// 视频播放器状态枚举
public enum ZCVideoPlayerStatus {
    case initial       // 初始状态
    case loading       // 正在加载
    case failed        // 加载失败
    case readyToPlay   // 准备播放
    case playing       // 正在播放
    case paused        // 暂停
    case finished      // 播放完成
}

/// 视频播放器接口协议
protocol ZCVideoPlayerIntf {
    /// 视频资源 URL
    var url: URL? { get set }
    
    /// 播放器当前状态
    var status: ZCVideoPlayerStatus { get }
    
    /// 状态变化的观察者
    var statusObservable: AnyPublisher<ZCVideoPlayerStatus, Never> { get }
    
    /// 视频总时长
    var duration: CMTime? { get }
    
    /// 当前播放时间的观察者
    var currentTimeObservable: AnyPublisher<CMTime, Never> { get }
    
    /// 视频尺寸（考虑旋转变换）
    var videoSize: CGSize? { get }
    
    /// 播放视频
    func play()
    
    /// 暂停视频
    func pause()
    
    /// 定位到指定时间，并在完成后调用回调
    func seek(to time: CMTime, completion: ((Bool) -> Void)?)
}

/// 默认视频播放器实现
class ZCVideoPlayer: NSObject, ZCVideoPlayerIntf {
    
    /// 内部使用的 AVPlayer 实例
    private(set) var player = AVPlayer()
    
    /// 需要观察的属性 keyPath 数组
    private let observedKeyPaths = [
        #keyPath(AVPlayer.timeControlStatus),
        #keyPath(AVPlayer.currentItem.status)
    ]
    
    /// 定时更新当前播放时间的观察者（用于 addPeriodicTimeObserver）
    private var timeObserver: Any?
    
    /// KVO 观察上下文标识
    private static var observerContext = 0
    
    /// 内部状态 subject，用于发布状态变化
    private var _status = CurrentValueSubject<ZCVideoPlayerStatus, Never>(.initial)
    
    /// 对外暴露的状态观察者
    private(set) lazy var statusObservable: AnyPublisher<ZCVideoPlayerStatus, Never> = {
        _status.eraseToAnyPublisher()
    }()
    
    /// 当前播放器状态
    var status: ZCVideoPlayerStatus {
        _status.value
    }
    
    /// 内部当前播放时间 subject
    private var _currentTime = CurrentValueSubject<CMTime, Never>(.zero)
    
    /// 对外暴露的当前播放时间观察者
    private(set) lazy var currentTimeObservable: AnyPublisher<CMTime, Never> = {
        _currentTime.eraseToAnyPublisher()
    }()
    
    /// 视频资源 URL：通过设置或获取当前 AVPlayerItem 中的 AVURLAsset 的 URL
    var url: URL? {
        get {
            (player.currentItem?.asset as? AVURLAsset)?.url
        }
        set {
            if let url = newValue {
                // 替换当前播放项
                replaceCurrentItem(AVPlayerItem(url: url))
            } else {
                replaceCurrentItem(nil)
            }
        }
    }
    
    /// 视频总时长
    var duration: CMTime? {
        player.currentItem?.duration
    }
    
    /// 视频尺寸（考虑视频旋转信息）
    var videoSize: CGSize? {
        guard let videoTrack = player.currentItem?.asset.tracks(withMediaType: .video).first else {
            return nil
        }
        // 通过应用视频轨道的 preferredTransform 计算实际显示尺寸
        return videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    }
    
    /// 初始化，支持传入 AVPlayerItem
    init(playerItem: AVPlayerItem? = nil) {
        super.init()
        // 添加 KVO 观察和定时器观察
        addPlayerObserve()
        if let playerItem = playerItem {
            replaceCurrentItem(playerItem)
        }
    }
    
    /// 通过 AVAsset 初始化播放器
    convenience init(asset: AVAsset) {
        self.init(playerItem: AVPlayerItem(asset: asset))
    }
    
    /// 通过 URL 初始化播放器
    convenience init(url: URL) {
        let asset = AVAsset(url: url)
        self.init(asset: asset)
    }
    
    deinit {
        // 移除通知和 KVO 观察
        NotificationCenter.default.removeObserver(self)
        removePlayerObserve()
    }
    
    /// 播放视频
    func play() {
        player.play()
    }
    
    /// 暂停视频
    func pause() {
        player.pause()
    }
    
    /// 定位到指定时间，并在定位完成后执行回调
    func seek(to time: CMTime, completion: ((Bool) -> Void)?) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
            guard let self = self else { return }
            if success {
                // 更新当前播放时间
                self._currentTime.value = self.player.currentTime()
            }
            completion?(success)
        }
    }
    
    /// 替换当前播放项，并更新播放完成的通知观察
    private func replaceCurrentItem(_ playerItem: AVPlayerItem?) {
        // 移除旧播放项对应的通知
        NotificationCenter.default.removeObserver(self,
                                                  name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                  object: player.currentItem)
        // 替换当前播放项
        player.replaceCurrentItem(with: playerItem)
        // 添加新的播放完成通知观察
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerDidFinishPlaying),
                                               name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                               object: playerItem)
    }
    
    /// 添加 KVO 和定时器观察，监控播放状态和时间变化
    private func addPlayerObserve() {
        // 添加 KVO 观察，监控 AVPlayer 的 timeControlStatus 和当前播放项的 status
        for keyPath in observedKeyPaths {
            player.addObserver(self,
                               forKeyPath: keyPath,
                               options: [.new, .initial],
                               context: &ZCVideoPlayer.observerContext)
        }
        
        // 添加周期性时间观察器，更新当前播放时间
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20),
                                                      queue: .main) { [weak self] time in
            guard let self = self else { return }
            self._currentTime.value = time
        }
    }
    
    /// 移除 KVO 和定时器观察
    private func removePlayerObserve() {
        // 移除周期性时间观察器
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        // 移除所有 KVO 观察
        for keyPath in observedKeyPaths {
            player.removeObserver(self,
                                  forKeyPath: keyPath,
                                  context: &ZCVideoPlayer.observerContext)
        }
    }
    
    /// 播放完成的通知回调
    @objc private func playerDidFinishPlaying() {
        _status.value = .finished
    }
    
    /// KVO 观察回调，监控 AVPlayer 及其当前播放项状态的变化
    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {
        // 确保是我们添加的观察回调
        guard context == &ZCVideoPlayer.observerContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }
        
        // 根据 keyPath 判断状态更新
        if keyPath == #keyPath(AVPlayer.timeControlStatus) {
            switch player.timeControlStatus {
            case .playing:
                _status.value = .playing
            case .paused:
                _status.value = .paused
            default:
                _status.value = .loading
            }
        } else if keyPath == #keyPath(AVPlayer.currentItem.status),
                  let playerItem = player.currentItem {
            switch playerItem.status {
            case .readyToPlay:
                _status.value = .readyToPlay
            default:
                _status.value = .failed
            }
        }
    }
}
