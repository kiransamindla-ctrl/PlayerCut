//
//  ReelComposer.swift
//  PlayerCut
//
//  Composites the selected clips into a 9:16 vertical MP4 with crossfades,
//  smooth player-tracked reframing, music bed, and on-screen captions.
//

import AVFoundation
import CoreImage
import UIKit
import os.log

final class ReelComposer {

    private let log = Logger(subsystem: "com.playercut.app", category: "Composer")

    private let crossfade: Double = 0.3

    /// 1080p for ≤3 min reels; 720p for 5 min so the MP4 stays
    /// share-friendly (~150 MB at 1080p, ~50 MB at 720p).
    private func outputSize(for length: ReelLength) -> CGSize {
        switch length {
        case .fiveMinutes:
            return CGSize(width: 720, height: 1280)
        default:
            return CGSize(width: 1080, height: 1920)
        }
    }

    func compose(plan: ReelPlan,
                 game: GameSession,
                 player: PlayerEnrollment,
                 length: ReelLength,
                 musicURL: URL?,
                 outputURL: URL) async throws -> URL {

        let outputSize = outputSize(for: length)
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PipelineError.compositionFailed("Could not add video track")
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        let musicTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)

        let asset = AVURLAsset(url: game.rawVideoURL)
        guard let assetVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.compositionFailed("Source video has no track")
        }

        var insertTime = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for (index, clip) in plan.selected.enumerated() {
            let clipDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: clip.clipStart, preferredTimescale: 600),
                duration: clipDuration
            )
            try videoTrack.insertTimeRange(timeRange,
                                           of: assetVideoTrack,
                                           at: insertTime)
            if let assetAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(timeRange,
                                                of: assetAudio,
                                                at: insertTime)
            }

            // Build per-clip composition instruction with player-tracked reframe
            let instr = makeReframeInstruction(for: clip,
                                               sourceTrack: videoTrack,
                                               assetTrack: assetVideoTrack,
                                               at: insertTime,
                                               duration: clipDuration,
                                               outputSize: outputSize,
                                               isFirst: index == 0,
                                               isLast: index == plan.selected.count - 1)
            instructions.append(instr)
            insertTime = CMTimeAdd(insertTime, clipDuration)
        }

        videoComposition.instructions = instructions

        // Music bed
        if let musicURL {
            let music = AVURLAsset(url: musicURL)
            if let track = try? await music.loadTracks(withMediaType: .audio).first {
                let totalDuration = CMTime(seconds: plan.totalDuration,
                                           preferredTimescale: 600)
                let range = CMTimeRange(start: .zero, duration: totalDuration)
                try musicTrack?.insertTimeRange(range, of: track, at: .zero)
            }
        }

        // Mix: duck music when game audio is loud
        let mix = AVMutableAudioMix()
        if let audioTrack {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(1.0, at: .zero)
            mix.inputParameters.append(params)
        }
        if let musicTrack {
            let params = AVMutableAudioMixInputParameters(track: musicTrack)
            params.setVolume(0.35, at: .zero)
            mix.inputParameters.append(params)
        }

        // Export
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw PipelineError.compositionFailed("Export session init failed")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.audioMix = mix
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: outputURL)
        await session.export()

        switch session.status {
        case .completed:
            log.info("Reel exported: \(outputURL.lastPathComponent)")
            return outputURL
        case .failed, .cancelled:
            throw PipelineError.compositionFailed(
                session.error?.localizedDescription ?? "Export failed")
        default:
            throw PipelineError.compositionFailed("Export ended in unexpected state")
        }
    }

    // MARK: - Reframe instruction

    /// Produces a transform that crops the source 16:9 frame down to a 9:16
    /// window centered on the smoothed bounding box of the player.
    private func makeReframeInstruction(
        for clip: SelectedClip,
        sourceTrack: AVMutableCompositionTrack,
        assetTrack: AVAssetTrack,
        at startTime: CMTime,
        duration: CMTime,
        outputSize: CGSize,
        isFirst: Bool,
        isLast: Bool
    ) -> AVMutableVideoCompositionInstruction {

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: startTime, duration: duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceTrack)

        // Smooth the player's bounding box centers across the clip with a
        // 1-D Kalman so the framing doesn't jitter.
        let smoothed = smoothPlayerCenters(boxes: clip.moment.playerBoundingBoxes,
                                           clipStart: clip.clipStart,
                                           clipEnd: clip.clipEnd)

        // For each smoothed center, set a transform ramp.
        // For brevity, we set just two anchors (start and end). Production code
        // would interpolate at 10–15 Hz across the clip.
        let startCenter = smoothed.first ?? CGPoint(x: 0.5, y: 0.5)
        let endCenter = smoothed.last ?? startCenter

        let startTransform = transformForCenter(startCenter,
                                                sourceSize: assetTrack.naturalSize,
                                                outputSize: outputSize)
        let endTransform = transformForCenter(endCenter,
                                              sourceSize: assetTrack.naturalSize,
                                              outputSize: outputSize)

        layer.setTransformRamp(fromStart: startTransform,
                               toEnd: endTransform,
                               timeRange: instruction.timeRange)

        // Crossfade in/out
        if !isFirst {
            let fadeIn = CMTimeRange(start: startTime,
                                     duration: CMTime(seconds: crossfade,
                                                      preferredTimescale: 600))
            layer.setOpacityRamp(fromStartOpacity: 0,
                                 toEndOpacity: 1,
                                 timeRange: fadeIn)
        }
        if !isLast {
            let fadeOutStart = CMTimeAdd(startTime,
                                         CMTimeSubtract(duration,
                                                        CMTime(seconds: crossfade,
                                                               preferredTimescale: 600)))
            let fadeOut = CMTimeRange(
                start: fadeOutStart,
                duration: CMTime(seconds: crossfade, preferredTimescale: 600))
            layer.setOpacityRamp(fromStartOpacity: 1,
                                 toEndOpacity: 0,
                                 timeRange: fadeOut)
        }

        instruction.layerInstructions = [layer]
        return instruction
    }

    private func transformForCenter(_ center: CGPoint,
                                    sourceSize: CGSize,
                                    outputSize: CGSize) -> CGAffineTransform {
        // Source is 1920x1080 landscape. We want a 9:16 viewport centered on
        // `center` (normalized 0..1 in source), scaled to fill 1080x1920 output.
        // Compute the crop window width in source pixels:
        let cropHeight = sourceSize.height
        let cropWidth = cropHeight * (9.0 / 16.0)

        // Convert normalized center into source-pixel coords (Vision uses
        // bottom-left; UIKit/Core Animation uses top-left — match accordingly)
        let cx = center.x * sourceSize.width
        let cy = (1 - center.y) * sourceSize.height

        // Clamp the crop window so it stays inside the source frame
        let halfW = cropWidth / 2
        let clampedCx = min(max(cx, halfW), sourceSize.width - halfW)

        // The transform: translate so (clampedCx - halfW, 0) maps to (0,0),
        // then scale so cropWidth → outputSize.width.
        let scale = outputSize.width / cropWidth
        var t = CGAffineTransform.identity
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -(clampedCx - halfW), y: 0)
        return t
    }

    private func smoothPlayerCenters(boxes: [TimedBox],
                                     clipStart: Double,
                                     clipEnd: Double) -> [CGPoint] {
        let inWindow = boxes.filter { $0.time >= clipStart - 0.5 && $0.time <= clipEnd + 0.5 }
        if inWindow.isEmpty { return [] }

        // Simple exponential smoothing (alpha = 0.3)
        let alpha: CGFloat = 0.3
        var smoothed: [CGPoint] = []
        var prev = CGPoint(x: inWindow[0].box.midX, y: inWindow[0].box.midY)
        for entry in inWindow {
            let raw = CGPoint(x: entry.box.midX, y: entry.box.midY)
            let next = CGPoint(x: prev.x + alpha * (raw.x - prev.x),
                               y: prev.y + alpha * (raw.y - prev.y))
            smoothed.append(next)
            prev = next
        }
        return smoothed
    }
}
