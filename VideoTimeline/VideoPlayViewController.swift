//
//  VideoPlayViewController.swift
//  VideoTimeline
//
//  Created by hope on 12/16/22.
//

import UIKit
import Combine

class VideoPlayViewController: UIViewController, ZCVideoTimelineViewDelegate {
    
    private var videoPlayer = ZCVideoPlayer()
    private let videoView = ZCVideoPlayerView()
    
    private lazy var videoTimelineView: ZCVideoTimelineView = {
        let timelineView = ZCVideoTimelineView()
        timelineView.delegate = self
        return timelineView
    }()
    
    private let playButton: UIButton = {
        let button = UIButton()
        button.contentMode = .scaleAspectFit
        button.contentVerticalAlignment = .fill
        button.contentHorizontalAlignment = .fill
        return button
    }()
    
    private var isPlaying = false
    private var cancellables = Set<AnyCancellable>()
        
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupView()
        bindVideoPlayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
     
        videoPlayer.url = Bundle.main.url(forResource: "sample", withExtension: "mp4")
        videoView.player = videoPlayer
    }
    
    private func setupView() {
        view.backgroundColor = .white
        
        view.addSubview(videoView)
        videoView.backgroundColor = UIColor(hex: "#EEF3F6FF")
        videoView.constraints(leading: view.safeAreaLayoutGuide.leadingAnchor,
                              top: view.safeAreaLayoutGuide.topAnchor,
                              trailing: view.safeAreaLayoutGuide.trailingAnchor)
        
        view.addSubview(videoTimelineView)
        videoTimelineView.backgroundColor = UIColor(hex: "#F4F4F4FF")
        videoTimelineView.constraints(leading: view.safeAreaLayoutGuide.leadingAnchor,
                                      top: videoView.bottomAnchor,
                                      trailing: view.safeAreaLayoutGuide.trailingAnchor,
                                      height: 200)
        view.addSubview(playButton)
        playButton.constraints(top: videoTimelineView.bottomAnchor,
                               bottom: view.safeAreaLayoutGuide.bottomAnchor,
                               paddingTop: 16,
                               paddingBottom: 16,
                               width: 32,
                               height: 32,
                               centerX: view.centerXAnchor)
        playButton.addTarget(self, action: #selector(onPlayButtonTapped), for: .touchUpInside)
        playButton.isHidden = true
    }
    
    private func bindVideoPlayer() {
        videoPlayer.statusObservable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else {
                    return
                }
                
                self.updatePlayButton(status)
                if status == .readyToPlay {
                    self.videoTimelineView.player = self.videoPlayer
                }
            }.store(in: &cancellables)
    }
    
    private func updatePlayButton(_ status: ZCVideoPlayerStatus) {
        isPlaying = status == .playing
        let image = isPlaying ? UIImage(systemName: "pause.fill") : UIImage(systemName: "play.fill")
        self.playButton.setImage(image, for: .normal)
    }
    
    @objc private func onPlayButtonTapped() {
        if isPlaying {
            videoPlayer.pause()
        } else {
            videoPlayer.play()
        }
    }
    
    // MARK: - VideoTimelineViewDelegate
    
    func timelineReady() {
        self.playButton.isHidden = false
    }
}

