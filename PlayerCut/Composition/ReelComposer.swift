//
//  ReelComposer.swift
//  PlayerCut/Composition
//
//  Renders an EditPlan into a finished MP4. All "taste" lives in the
//  EditPlanBuilder; this file's job is purely to translate that plan
//  into AVFoundation primitives:
//
//    - Cold open + body clips inserted via AVMutableComposition with
//      per-segment time-range scaling (= speed ramps).
//    - A custom CinematicCompositor on the AVMutableVideoComposition,
//      one CinematicInstruction per rendered clip — interpolates crop
//      keyframes, applies the LUT grade, and blends transitions.
//    - Title + closing cards rendered into solid-black source segments
//      with Core Animation layers attached via
//      AVVideoCompositionCoreAnimationTool.
//    - Music bed + game audio mix with per-clip ducking and an
//      always-on closing fade so the reel ends clean.
//

import AVFoundation
import CoreImage
import QuartzCore
import UIKit
import os.log

final class ReelComposer {

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "Composer")

    struct Result {
        let localURL: URL
        let savedToPhotos: Bool
        let assetId: String?
    }

    // Knobs surfaced to the orchestrator so device-class gating can
    // turn off heavy stages on weaker hardware. See PerfProfile in
    // EditPlanBuilder for the read side of these.
    var enableTitleCards: Bool = true
    var enableLowerThird: Bool = true
    var enableClosingCard: Bool = true
    var transitionDuration: Double = 0.45
    var musicBedVolume: Float = 0.40        // -8.5 dB ≈ 0.376; rounded
    var musicDuckVolume: Float = 0.08       // -22 dB ≈ 0.079; rounded
    var gameAudioVolume: Float = 1.0

    func compose(plan: EditPlan,
                 game: GameSession,
                 player: PlayerEnrollment,
                 outputURL: URL) async throws -> Result {

        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = plan.output.size
        videoComposition.frameDuration = CMTime(value: 1,
                                                timescale: Int32(plan.output.fps))
        videoComposition.customVideoCompositorClass = CinematicCompositor.self

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

        // Open the source asset once and look up its primary tracks.
        let asset = AVURLAsset(url: game.rawVideoURL)
        guard let assetVideoTrack = try await asset.loadTracks(
                withMediaType: .video).first else {
            throw PipelineError.compositionFailed("Source video has no track")
        }
        let assetAudioTrack = try? await asset.loadTracks(
            withMediaType: .audio).first

        // Build the rendered segments in order:
        // [cold open] [title card] [body...] [closing card]
        // For each video segment we record a (renderTimeRange, instruction)
        // pair so the video composition's instructions array stays in
        // strict chronological order.

        var insertTime = CMTime.zero
        var instructions: [CinematicInstruction] = []
        var audioDuckRanges: [CMTimeRange] = []
        let stageStart = Date()
        var firstBodyOutputStart: Double = 0
        var lastBodyOutputEnd: Double = 0

        // Cold open ----------------------------------------------------
        if let cold = plan.coldOpen {
            try insertClip(cold,
                           composition: composition,
                           videoTrack: videoTrack,
                           audioTrack: audioTrack,
                           assetVideoTrack: assetVideoTrack,
                           assetAudioTrack: assetAudioTrack,
                           plan: plan,
                           at: &insertTime,
                           instructions: &instructions,
                           transitionInto: nil)
        }

        // Title card (solid-black source) -----------------------------
        if enableTitleCards, plan.titleCard != nil {
            let cardDuration = TitleCardSpec.duration
            try insertBlackCard(duration: cardDuration,
                                composition: composition,
                                videoTrack: videoTrack,
                                at: &insertTime,
                                instructions: &instructions,
                                plan: plan)
        }

        // Body clips ---------------------------------------------------
        firstBodyOutputStart = insertTime.seconds
        for (i, clip) in plan.body.enumerated() {
            let isLast = (i == plan.body.count - 1)
            let next: ClipPlan? = isLast ? nil : plan.body[i + 1]
            try insertClip(clip,
                           composition: composition,
                           videoTrack: videoTrack,
                           audioTrack: audioTrack,
                           assetVideoTrack: assetVideoTrack,
                           assetAudioTrack: assetAudioTrack,
                           plan: plan,
                           at: &insertTime,
                           instructions: &instructions,
                           transitionInto: next)
            // Duck music whenever the game audio is high-energy.
            if clip.energy >= 0.6 {
                let dur = max(0.3, min(0.9, Double(clip.renderedDuration)))
                let start = insertTime - CMTime(seconds: dur,
                                                preferredTimescale: 600)
                audioDuckRanges.append(
                    CMTimeRange(start: start,
                                duration: CMTime(seconds: dur,
                                                 preferredTimescale: 600)))
            }
        }
        lastBodyOutputEnd = insertTime.seconds

        // Closing card -------------------------------------------------
        let closingStart = insertTime.seconds
        if enableClosingCard, plan.closingCard != nil {
            let cardDuration = ClosingCardSpec.duration
            try insertBlackCard(duration: cardDuration,
                                composition: composition,
                                videoTrack: videoTrack,
                                at: &insertTime,
                                instructions: &instructions,
                                plan: plan)
        }

        // Music bed ----------------------------------------------------
        let totalDuration = insertTime
        if let musicURL = plan.musicURL {
            let music = AVURLAsset(url: musicURL)
            if let track = try? await music.loadTracks(
                withMediaType: .audio).first {
                let range = CMTimeRange(start: .zero, duration: totalDuration)
                try? musicTrack?.insertTimeRange(range,
                                                 of: track,
                                                 at: .zero)
            }
        }

        videoComposition.instructions = instructions
        videoComposition.customVideoCompositorClass = CinematicCompositor.self

        // Title + closing + lower-third overlays via Core Animation ----
        if enableTitleCards || enableLowerThird || enableClosingCard {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: plan.output.size)
            let video = CALayer()
            video.frame = parent.bounds
            parent.addSublayer(video)

            // titleStart = right after cold open (if any).
            let titleStart: Double = (plan.coldOpen?.renderedDuration ?? 0)
            // lowerThird starts inside the first body clip.
            let lowerThirdStart = firstBodyOutputStart
            let overlay = TitleCardFactory.buildOverlay(
                size: plan.output.size,
                plan: plan,
                titleStart: titleStart,
                lowerThirdStart: lowerThirdStart,
                closingStart: closingStart)
            parent.addSublayer(overlay)

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: video,
                in: parent)
        }

        // Audio mix ----------------------------------------------------
        let mix = AVMutableAudioMix()
        if let audioTrack {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(gameAudioVolume, at: .zero)
            mix.inputParameters.append(params)
        }
        if let musicTrack {
            let params = AVMutableAudioMixInputParameters(track: musicTrack)
            // Base level, then duck around each high-energy moment, then
            // recover. Final fade-out across the closing card.
            params.setVolume(musicBedVolume, at: .zero)
            for range in audioDuckRanges {
                params.setVolumeRamp(
                    fromStartVolume: musicBedVolume,
                    toEndVolume: musicDuckVolume,
                    timeRange: CMTimeRange(start: range.start,
                                           duration: CMTime(seconds: 0.25,
                                                            preferredTimescale: 600)))
                params.setVolumeRamp(
                    fromStartVolume: musicDuckVolume,
                    toEndVolume: musicBedVolume,
                    timeRange: CMTimeRange(start: range.end,
                                           duration: CMTime(seconds: 0.4,
                                                            preferredTimescale: 600)))
            }
            // Closing fade.
            let fadeStart = CMTime(seconds: max(0, lastBodyOutputEnd),
                                   preferredTimescale: 600)
            let fadeEnd = totalDuration
            params.setVolumeRamp(fromStartVolume: musicBedVolume,
                                 toEndVolume: 0,
                                 timeRange: CMTimeRange(start: fadeStart,
                                                        end: fadeEnd))
            mix.inputParameters.append(params)
        }

        // Export -------------------------------------------------------
        let preset = pickExportPreset(asset: composition)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: preset) else {
            throw PipelineError.compositionFailed(
                "Export session init failed for preset \(preset)")
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
            break
        case .failed, .cancelled:
            throw PipelineError.compositionFailed(
                session.error?.localizedDescription ?? "Export failed")
        default:
            throw PipelineError.compositionFailed("Export ended in unexpected state")
        }

        // Belt-and-braces: don't publish a half-written file. Confirm
        // the writer has flushed before we hand the URL to anyone.
        let fm = FileManager.default
        var attempts = 0
        while attempts < 20 {
            if fm.fileExists(atPath: outputURL.path),
               let attrs = try? fm.attributesOfItem(atPath: outputURL.path),
               let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard fm.fileExists(atPath: outputURL.path),
              let attrs = try? fm.attributesOfItem(atPath: outputURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else {
            throw PipelineError.compositionFailed(
                "Export reported completed but output file is missing or empty")
        }

        log.info("Reel exported: \(outputURL.lastPathComponent, privacy: .public) (\(size) bytes) in \(Date().timeIntervalSince(stageStart), format: .fixed(precision: 2))s")

        let outcome = await PhotosLibraryService.saveReel(fileURL: outputURL)
        switch outcome {
        case .savedToAlbumAndRecents(let id):
            return Result(localURL: outputURL, savedToPhotos: true, assetId: id)
        case .savedToRecents(let id):
            return Result(localURL: outputURL, savedToPhotos: true, assetId: id)
        case .permissionDenied, .failed:
            return Result(localURL: outputURL, savedToPhotos: false, assetId: nil)
        }
    }

    // MARK: - Clip insertion (handles speed curve)

    private func insertClip(_ clip: ClipPlan,
                            composition: AVMutableComposition,
                            videoTrack: AVMutableCompositionTrack,
                            audioTrack: AVMutableCompositionTrack?,
                            assetVideoTrack: AVAssetTrack,
                            assetAudioTrack: AVAssetTrack?,
                            plan: EditPlan,
                            at insertTime: inout CMTime,
                            instructions: inout [CinematicInstruction],
                            transitionInto next: ClipPlan?) throws {

        let segmentStart = insertTime
        let srcDur = clip.sourceEnd - clip.sourceStart
        guard srcDur > 0 else { return }

        // Walk the speed curve, emitting per-segment insertTimeRange +
        // scaleTimeRange calls. After all segments are inserted, the
        // overall rendered duration matches clip.renderedDuration.
        for seg in clip.speedCurve.segments {
            let sFrac = seg.sourceFractionStart
            let eFrac = seg.sourceFractionEnd
            guard eFrac > sFrac else { continue }
            let segSourceDur = srcDur * (eFrac - sFrac)
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart + srcDur * sFrac,
                              preferredTimescale: 600),
                duration: CMTime(seconds: segSourceDur,
                                 preferredTimescale: 600))
            try videoTrack.insertTimeRange(sourceRange,
                                           of: assetVideoTrack,
                                           at: insertTime)
            if let aTrack = audioTrack, let aSrc = assetAudioTrack {
                try? aTrack.insertTimeRange(sourceRange,
                                            of: aSrc,
                                            at: insertTime)
            }
            // Scale the newly-inserted range. Output duration = source /
            // factor.
            let inserted = CMTimeRange(
                start: insertTime,
                duration: CMTime(seconds: segSourceDur,
                                 preferredTimescale: 600))
            let scaled = CMTime(seconds: segSourceDur / max(0.01, seg.factor),
                                preferredTimescale: 600)
            videoTrack.scaleTimeRange(inserted, toDuration: scaled)
            if let aTrack = audioTrack {
                aTrack.scaleTimeRange(inserted, toDuration: scaled)
            }
            insertTime = CMTimeAdd(insertTime, scaled)
        }

        // Build the per-clip CinematicInstruction. Transition window
        // sits at the very tail of the clip.
        let renderedDur = insertTime.seconds - segmentStart.seconds
        let outRange = CMTimeRange(start: segmentStart,
                                   duration: CMTime(seconds: renderedDur,
                                                    preferredTimescale: 600))
        var transitionKind: TransitionKind? = nil
        var transitionStart: Double? = nil
        var transitionEnd: Double? = nil
        if next != nil {
            let dur = min(transitionDuration, max(0.18, renderedDur * 0.25))
            transitionKind = clip.outgoingTransition
            transitionEnd = segmentStart.seconds + renderedDur
            transitionStart = transitionEnd! - dur
        }

        let instr = CinematicInstruction(
            timeRange: outRange,
            startSeconds: segmentStart.seconds,
            trackAID: videoTrack.trackID,
            trackBID: nil,
            cropKeyframes: clip.cropKeyframes,
            look: plan.style.lookUpTable,
            transitionKind: transitionKind,
            transitionStart: transitionStart,
            transitionEnd: transitionEnd)
        instructions.append(instr)
    }

    // MARK: - Title / closing card (black source segment)

    /// AVMutableComposition can't insert "blank" video — we need real
    /// source pixels. Strategy: insert a tiny slice of source video
    /// (any frame will do) and let the custom compositor cover it with
    /// a Core Animation layer in front. The compositor's vignette +
    /// LUT pass on a 1.0-scale crop will still produce a "video frame"
    /// underneath, but the title overlay layer on top hides it.
    /// Cheap and avoids bundling a black asset.
    private func insertBlackCard(duration: Double,
                                 composition: AVMutableComposition,
                                 videoTrack: AVMutableCompositionTrack,
                                 at insertTime: inout CMTime,
                                 instructions: inout [CinematicInstruction],
                                 plan: EditPlan) throws {
        let segmentStart = insertTime
        let cardDur = CMTime(seconds: duration, preferredTimescale: 600)

        // Reuse the existing video track's last 0.5s frozen via scale
        // — but the simplest approach that doesn't depend on prior
        // tracks is to insert an empty time range, which AVFoundation
        // renders as black with our custom compositor.
        videoTrack.insertEmptyTimeRange(
            CMTimeRange(start: insertTime, duration: cardDur))
        insertTime = CMTimeAdd(insertTime, cardDur)

        // For empty ranges we still need an instruction covering the
        // span. The compositor will receive no source frames; our
        // applyCropAndGrade short-circuits on missing source, so the
        // overlay-only layer (driven by Core Animation) renders alone.
        let outRange = CMTimeRange(start: segmentStart, duration: cardDur)
        let instr = CinematicInstruction(
            timeRange: outRange,
            startSeconds: segmentStart.seconds,
            trackAID: videoTrack.trackID,
            trackBID: nil,
            cropKeyframes: [CropKeyframe(time: 0,
                                         center: CGPoint(x: 0.5, y: 0.5),
                                         scale: 1.0)],
            look: plan.style.lookUpTable,
            transitionKind: nil,
            transitionStart: nil,
            transitionEnd: nil)
        instructions.append(instr)
    }

    // MARK: - Preset

    /// Prefer HEVC. The 1080p HEVC preset gives us ~50% smaller files
    /// at the same quality vs the highest-quality H.264 preset. Fall
    /// back to highestQuality (H.264-compatible) when HEVC isn't
    /// available for the current composition.
    private func pickExportPreset(asset: AVAsset) -> String {
        let hevc1080 = AVAssetExportPresetHEVC1920x1080
        let compatible = AVAssetExportSession
            .exportPresets(compatibleWith: asset)
        if compatible.contains(hevc1080) { return hevc1080 }
        return AVAssetExportPresetHighestQuality
    }
}
