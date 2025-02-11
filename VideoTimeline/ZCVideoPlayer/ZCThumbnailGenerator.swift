//
//  ThumbnailGenerator.swift
//  VideoTimeline
//
//
import AVFoundation

class ZCThumbnailGenerator {
    
    private let assetImageGenerator: AVAssetImageGenerator
    private let videoDuration: Double
    private var thumbIndex = 0
    
    init(url: URL) {
        let asset = AVAsset(url: url)
        
        videoDuration = asset.duration.seconds
        assetImageGenerator = AVAssetImageGenerator(asset: asset)
        assetImageGenerator.appliesPreferredTrackTransform = true
        assetImageGenerator.requestedTimeToleranceBefore = .zero
        assetImageGenerator.requestedTimeToleranceAfter = .zero
    }
    
    deinit {
        assetImageGenerator.cancelAllCGImageGeneration()
    }
    
    func requestThumbnails(intervalSeconds: Double, maxSize: CGSize, completion: @escaping (CGImage?, Int, Int) -> Void) {
        let interval = intervalSeconds
        let duration = videoDuration
        var thumbCount = Int(duration / interval)
        var thumbTimes = [NSValue]()
        
        if Double(thumbCount) * interval < duration {
            thumbCount += 1
        }
        for i in 0..<thumbCount {
            let time = CMTime(value: CMTimeValue(Double(i) * interval), timescale: 1)
            thumbTimes.append(NSValue(time: time))
        }
        
        thumbIndex = 0
        assetImageGenerator.maximumSize = maxSize
        assetImageGenerator.generateCGImagesAsynchronously(forTimes: thumbTimes) { [weak self] requestedTime, cgImage, actualTime, result, error in
            guard let self = self else {
                return
            }
            completion(cgImage, self.thumbIndex, thumbTimes.count)
            self.thumbIndex += 1
        }
    }
}
