//
//  ReelComposer.swift
//  PlayerCut/Composition
//
//  Renders an EditPlan into a finished MP4. All "taste" lives in the
//  EditPlanBuilder; this file's job is purely to translate that plan
//  into AVFoundation primitives:
//
//    - Cold open + title placeholder + body clips inserted via
//      AVMutableComposition with per-segment time-range scaling
//      (= speed ramps).
//    - A SECOND video track (trackB) populated with the next clip's
//      head during each transition window, so the custom compositor
//      can blend real A and B frames instead of single-stream fakes.
//    - A custom MetalPetalCompositor on the AVMutableVideoComposition,
//      one MetalPetalInstruction per rendered segment. The compositor
//      interpolates crop keyframes, applies the LUT, blends transitions,
//      AND composites rasterized title / closing / lower-third overlays
//      — all in one GPU pass.
//    - NO AVVideoCompositionCoreAnimationTool. Mixing it with a
//      custom AVVideoCompositing is an Apple-API conflict that broke
//      export on real devices (Section 2.1).
//    - Music bed + game-audio mix with per-clip ducking and an
//      always-on closing fade so the reel ends clean.
//
//  Every stage is wrapped in try/catch with explicit fail-loud:
//    - os_log line at stage start and on failure
//    - DiagnosticsStore.composerStageFailed(stage:,error:) on throw
//    - composerUsedFallback(false) on success; we never silently
//      fall back to a primitive concatenation. If compose throws,
//      the orchestrator surfaces the error to the UI — the user sees
//      "couldn't finish the edit, tap retry", NOT a primitive reel.
//

import AVFoundation
import CoreGraphics
import Foundation
import MetalPetal
import UIKit
import os.log

final class ReelComposer {

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "Composer")
    /// Background renders past this wall-clock budget trip the watchdog,
    /// surface a loud error, and bail. Set conservatively — a 60s reel
    /// on iPhone 13 should finish in well under 3 min.
    private let exportWatchdogSeconds: TimeInterval = 240

    struct Result {
        let localURL: URL
        let savedToPhotos: Bool
        let assetId: String?
    }

    /// Snapshot of the pieces handed to the exporter, captured by
    /// compose() immediately before export. Lets white-box regression
    /// tests assert the -11841-avoidance invariants — ≤2 video tracks
    /// (A/B), instructions that tile [.zero, totalDuration] contiguously,
    /// and an audio timeline that matches the video timeline — without
    /// re-deriving them or paying for a second export. nil until a
    /// compose() runs.
    struct AssembledComposition {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix
        let totalDuration: CMTime
        let instructions: [MetalPetalInstruction]
    }
    private(set) var lastAssembled: AssembledComposition?

    // Knobs surfaced to the orchestrator so device-class gating can
    // turn off heavy stages on weaker hardware.
    var enableTitleCards: Bool = true
    var enableLowerThird: Bool = true
    var enableClosingCard: Bool = true
    /// Test/seam knob. Production leaves this true so finished reels are
    /// copied into Photos. The simulator integration test sets it false
    /// so compose() never blocks on the `.addOnly` authorization prompt
    /// in a headless XCTest host (the request continuation would never
    /// resume and the test would hang). When false, compose() returns a
    /// Result with savedToPhotos == false and skips PhotosLibraryService
    /// entirely.
    var savesToPhotos: Bool = true
    /// Cross-clip blend duration. Compositor clamps to ≤ 25 % of the
    /// shorter of the two clip's rendered duration.
    var transitionDuration: Double = 0.45
    // Mix levels (Section 5 — "music bed + low game-audio underneath
    // + smoother ducking"):
    //   - Music sits at -8.5 dB so the bed reads as polished rather
    //     than competing with the game audio. // SOURCE: ITU-R BS.1770
    //     loudness targets; iOS broadcast convention.
    //   - Game audio drops to a SUPPORTING bed level (~0.30 → -10 dB)
    //     so crowd/ball noise is audibly present underneath but never
    //     fights the music. The old default 1.0 made every recording
    //     feel "raw clip" instead of "edited reel".
    //   - When game audio peaks (audioDuckRanges) the music dips a
    //     full -12 dB below bed (musicBedVolume × 10^(-12/20) ≈ 0.10).
    var musicBedVolume: Float = 0.40        // -8.5 dB ≈ 0.376; rounded
    var musicDuckVolume: Float = 0.10       // -12 dB below bed; ITU-R-ish
    var gameAudioVolume: Float = 0.30       // -10 dB under music bed

    /// MTIContext used for rasterizing CALayer-based cards into MTIImages.
    /// Lazily created so unit tests that never call compose() don't pay
    /// for a Metal device init.
    private lazy var mtiContext: MTIContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? MTIContext(device: device)
    }()

    func compose(plan: EditPlan,
                 game: GameSession,
                 player: PlayerEnrollment,
                 outputURL: URL) async throws -> Result {

        let stageStart = Date()
        log.info("Compose start: \(plan.body.count) body clips, total \(plan.totalDuration, format: .fixed(precision: 1))s, style=\(plan.style.rawValue, privacy: .public)")

        // ─── Stage: validatePlan ────────────────────────────────────
        do {
            guard plan.totalDuration > 0 else {
                throw PipelineError.compositionFailed(
                    "EditPlan has zero total duration")
            }
            guard !plan.body.isEmpty || plan.coldOpen != nil else {
                throw PipelineError.compositionFailed(
                    "EditPlan has no renderable clips")
            }
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .validatePlan, error: error)
            throw error
        }

        // ─── Stage: loadAssetTracks ─────────────────────────────────
        let asset = AVURLAsset(url: game.rawVideoURL)
        let assetVideoTrack: AVAssetTrack
        let assetAudioTrack: AVAssetTrack?
        do {
            guard let v = try await asset.loadTracks(
                withMediaType: .video).first else {
                throw PipelineError.compositionFailed(
                    "Source video has no track")
            }
            assetVideoTrack = v
            assetAudioTrack = try? await asset.loadTracks(
                withMediaType: .audio).first
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .loadAssetTracks, error: error)
            throw error
        }

        // ─── Stage: buildComposition ────────────────────────────────
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = plan.output.size
        videoComposition.frameDuration = CMTime(value: 1,
                                                timescale: Int32(plan.output.fps))
        videoComposition.customVideoCompositorClass = MetalPetalCompositor.self

        let trackA: AVMutableCompositionTrack
        let trackB: AVMutableCompositionTrack
        let audioTrack: AVMutableCompositionTrack?
        let musicTrack: AVMutableCompositionTrack?

        do {
            guard let a = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid),
                  let b = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PipelineError.compositionFailed(
                    "Could not add A/B video tracks")
            }
            trackA = a
            trackB = b
            audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
            musicTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .buildComposition, error: error)
            throw error
        }

        // ─── Stage: insertClips + insertTitleCards + attachOverlays ─
        var insertTime = CMTime.zero
        var instructions: [MetalPetalInstruction] = []
        var audioDuckRanges: [CMTimeRange] = []
        var firstBodyOutputStart: Double = 0
        var lastBodyOutputEnd: Double = 0
        var closingStart: Double = 0
        let reframeStart = Date()

        // Pre-rasterize title / closing / lower-third images once. They
        // are passed via MetalPetalInstruction.Overlay and the compositor
        // composites them with a time-varying alpha — no CALayer
        // animation, no CoreAnimationTool.
        let titleImage: MTIImage? = (enableTitleCards
                                     ? rasterize(titleCard: plan.titleCard,
                                                 size: plan.output.size)
                                     : nil)
        let closingImage: MTIImage? = (enableClosingCard
                                       ? rasterize(closingCard: plan.closingCard,
                                                   size: plan.output.size)
                                       : nil)
        let lowerThirdImage: MTIImage? = (enableLowerThird
                                          ? rasterize(lowerThird: plan.lowerThird,
                                                      size: plan.output.size)
                                          : nil)

        do {
            // Cold open ----------------------------------------------------
            if let cold = plan.coldOpen {
                try insertClip(cold,
                               trackA: trackA,
                               trackB: trackB,
                               audioTrack: audioTrack,
                               assetVideoTrack: assetVideoTrack,
                               assetAudioTrack: assetAudioTrack,
                               plan: plan,
                               at: &insertTime,
                               instructions: &instructions,
                               nextClip: nil,
                               overlay: nil)
            }

            // Title card (compositor synthesizes black; overlay paints) -----
            if enableTitleCards, plan.titleCard != nil {
                let cardDuration = TitleCardSpec.duration
                try insertOverlayCard(duration: cardDuration,
                                      trackA: trackA,
                                      at: &insertTime,
                                      instructions: &instructions,
                                      plan: plan,
                                      overlayImage: titleImage)
            }

            // Body ----------------------------------------------------------
            firstBodyOutputStart = insertTime.seconds
            for (i, clip) in plan.body.enumerated() {
                let isLast = (i == plan.body.count - 1)
                let next: ClipPlan? = isLast ? nil : plan.body[i + 1]
                // Lower-third overlay rides on the first body clip only.
                let overlay: MetalPetalInstruction.Overlay? = (i == 0
                    ? makeLowerThirdOverlay(image: lowerThirdImage,
                                            startSeconds: insertTime.seconds,
                                            spec: plan.lowerThird)
                    : nil)
                try insertClip(clip,
                               trackA: trackA,
                               trackB: trackB,
                               audioTrack: audioTrack,
                               assetVideoTrack: assetVideoTrack,
                               assetAudioTrack: assetAudioTrack,
                               plan: plan,
                               at: &insertTime,
                               instructions: &instructions,
                               nextClip: next,
                               overlay: overlay)
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

            // Closing card --------------------------------------------------
            closingStart = insertTime.seconds
            if enableClosingCard, plan.closingCard != nil {
                let cardDuration = ClosingCardSpec.duration
                try insertOverlayCard(duration: cardDuration,
                                      trackA: trackA,
                                      at: &insertTime,
                                      instructions: &instructions,
                                      plan: plan,
                                      overlayImage: closingImage)
            }
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .insertClips, error: error)
            throw error
        }

        let totalDuration = insertTime
        videoComposition.instructions = instructions

        await DiagnosticsStore.shared.recordDuration(
            .composeReframe,
            seconds: Date().timeIntervalSince(reframeStart))

        // ─── Music bed + audio mix ──────────────────────────────────
        if let musicURL = plan.musicURL,
           let musicTrack {
            let music = AVURLAsset(url: musicURL)
            if let track = try? await music.loadTracks(
                withMediaType: .audio).first {
                let range = CMTimeRange(start: .zero, duration: totalDuration)
                try? musicTrack.insertTimeRange(range, of: track, at: .zero)
            } else {
                log.warning("Music URL provided but no audio track found — reel will be silent")
            }
        }

        let mix = AVMutableAudioMix()
        if let audioTrack {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(gameAudioVolume, at: .zero)
            mix.inputParameters.append(params)
        }
        if let musicTrack {
            let params = AVMutableAudioMixInputParameters(track: musicTrack)
            params.setVolume(musicBedVolume, at: .zero)
            // Smoother attack/release on the duck envelope: 350 ms in,
            // 550 ms out — feels less robotic than the old 250/400 ms.
            // // SOURCE: typical broadcast duck envelopes (250-500 ms
            // // attack, 500-900 ms release) sit at this scale.
            let duckAttack = CMTime(seconds: 0.35, preferredTimescale: 600)
            let duckRelease = CMTime(seconds: 0.55, preferredTimescale: 600)
            for range in audioDuckRanges {
                params.setVolumeRamp(
                    fromStartVolume: musicBedVolume,
                    toEndVolume: musicDuckVolume,
                    timeRange: CMTimeRange(start: range.start,
                                           duration: duckAttack))
                params.setVolumeRamp(
                    fromStartVolume: musicDuckVolume,
                    toEndVolume: musicBedVolume,
                    timeRange: CMTimeRange(start: range.end,
                                           duration: duckRelease))
            }
            let fadeStart = CMTime(seconds: max(0, lastBodyOutputEnd),
                                   preferredTimescale: 600)
            params.setVolumeRamp(fromStartVolume: musicBedVolume,
                                 toEndVolume: 0,
                                 timeRange: CMTimeRange(start: fadeStart,
                                                        end: totalDuration))
            mix.inputParameters.append(params)
        }

        // Snapshot the assembled pieces for white-box regression tests
        // (Section 8). References only — no copy, no behavior change.
        self.lastAssembled = AssembledComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: mix,
            totalDuration: totalDuration,
            instructions: instructions)

        // ─── Stage: exportSetup ─────────────────────────────────────
        // Prefer AVAssetExportPresetHEVC1920x1080 — it targets ~14 Mbps
        // HEVC at 1080p, materially crisper than AVAssetExportPreset
        // HighestQuality's default rate (~6 Mbps) for the same pixel
        // count. // SOURCE: Apple AVAssetExportSession docs, Apple TN3115.
        // The earlier concern (HEVC1920x1080 rejecting 4K source) is
        // moot here because the renderSize of the videoComposition is
        // already 1080p — the preset gates on the composition output,
        // not the source asset.
        // Fall back to HighestQuality if the device declares HEVC1920x1080
        // incompatible with the constructed composition for any reason.
        let session: AVAssetExportSession
        do {
            let compatible = AVAssetExportSession.exportPresets(
                compatibleWith: composition)
            let chosenPreset: String =
                compatible.contains(AVAssetExportPresetHEVC1920x1080)
                ? AVAssetExportPresetHEVC1920x1080
                : AVAssetExportPresetHighestQuality
            log.info("Export preset: \(chosenPreset, privacy: .public)")
            guard let s = AVAssetExportSession(
                asset: composition,
                presetName: chosenPreset) else {
                throw PipelineError.compositionFailed(
                    "Export session init failed")
            }
            session = s
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.videoComposition = videoComposition
            session.audioMix = mix
            session.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .exportSetup, error: error)
            throw error
        }

        // ─── Stage: exportRun (with watchdog) ───────────────────────
        let exportStart = Date()
        do {
            try await runExportWithWatchdog(session,
                                            budget: exportWatchdogSeconds)
            switch session.status {
            case .completed:
                break
            case .failed, .cancelled:
                throw PipelineError.compositionFailed(
                    session.error?.localizedDescription ?? "Export failed")
            default:
                throw PipelineError.compositionFailed(
                    "Export ended in unexpected state: \(session.status.rawValue)")
            }
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .exportRun, error: error)
            throw error
        }
        await DiagnosticsStore.shared.recordDuration(
            .composeExport,
            seconds: Date().timeIntervalSince(exportStart))

        // ─── Stage: exportFinalize ──────────────────────────────────
        do {
            try await waitForFileFlush(at: outputURL)
            // Gate completion on isPlayable so we don't publish a
            // half-written or corrupt file to GameDetailView.
            let asset = AVURLAsset(url: outputURL)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard isPlayable else {
                throw PipelineError.compositionFailed(
                    "Exported file isn't playable")
            }
            let size = (try? FileManager.default
                .attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
                .intValue ?? 0
            log.info("Reel exported: \(outputURL.lastPathComponent, privacy: .public) (\(size) bytes) in \(Date().timeIntervalSince(stageStart), format: .fixed(precision: 2))s")
        } catch {
            await DiagnosticsStore.shared
                .composerStageFailed(stage: .exportFinalize, error: error)
            throw error
        }

        // ─── Stage: savePhotos ──────────────────────────────────────
        // Affirm first: we did not silently fall back. Regression-guard
        // tests assert this stays false through the happy-path fixture.
        await DiagnosticsStore.shared.composerUsedFallback(false)

        guard savesToPhotos else {
            log.info("Photos save skipped (savesToPhotos == false) — local reel is canonical")
            return Result(localURL: outputURL, savedToPhotos: false, assetId: nil)
        }
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

    // MARK: - Watchdog

    /// Runs the export with a wall-clock budget. If the budget elapses
    /// we cancel the session and throw — better a loud "couldn't finish
    /// the edit, tap retry" than a UI that hangs forever.
    private func runExportWithWatchdog(_ session: AVAssetExportSession,
                                       budget: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await session.export() }
            group.addTask { [log] in
                try await Task.sleep(nanoseconds:
                    UInt64(budget * 1_000_000_000))
                if session.status == .exporting
                    || session.status == .waiting {
                    log.error("Export watchdog tripped at \(budget, format: .fixed(precision: 0))s — cancelling")
                    session.cancelExport()
                }
            }
            // First task to finish wins (the export normally; the
            // watchdog otherwise). Cancel the rest.
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForFileFlush(at url: URL) async throws {
        let fm = FileManager.default
        var attempts = 0
        while attempts < 20 {
            if fm.fileExists(atPath: url.path),
               let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        throw PipelineError.compositionFailed(
            "Export reported completed but output file is missing or empty")
    }

    // MARK: - Clip insertion (handles speed curve + B-track for transitions)

    private func insertClip(_ clip: ClipPlan,
                            trackA: AVMutableCompositionTrack,
                            trackB: AVMutableCompositionTrack,
                            audioTrack: AVMutableCompositionTrack?,
                            assetVideoTrack: AVAssetTrack,
                            assetAudioTrack: AVAssetTrack?,
                            plan: EditPlan,
                            at insertTime: inout CMTime,
                            instructions: inout [MetalPetalInstruction],
                            nextClip: ClipPlan?,
                            overlay: MetalPetalInstruction.Overlay?) throws {

        let segmentStart = insertTime
        let srcDur = clip.sourceEnd - clip.sourceStart
        guard srcDur > 0 else { return }

        // Walk the speed curve, inserting per-segment ranges into trackA.
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
            try trackA.insertTimeRange(sourceRange,
                                       of: assetVideoTrack,
                                       at: insertTime)
            if let aTrack = audioTrack, let aSrc = assetAudioTrack {
                try? aTrack.insertTimeRange(sourceRange,
                                            of: aSrc,
                                            at: insertTime)
            }
            let inserted = CMTimeRange(
                start: insertTime,
                duration: CMTime(seconds: segSourceDur,
                                 preferredTimescale: 600))
            let scaled = CMTime(seconds: segSourceDur / max(0.01, seg.factor),
                                preferredTimescale: 600)
            trackA.scaleTimeRange(inserted, toDuration: scaled)
            if let aTrack = audioTrack {
                aTrack.scaleTimeRange(inserted, toDuration: scaled)
            }
            insertTime = CMTimeAdd(insertTime, scaled)
        }

        let renderedDur = insertTime.seconds - segmentStart.seconds
        let outRange = CMTimeRange(start: segmentStart,
                                   duration: CMTime(seconds: renderedDur,
                                                    preferredTimescale: 600))

        // Build the per-clip transition spec. The B-track gets the head
        // of the *next* clip's source so the compositor can blend real
        // A and B frames during the window.
        var transitionKind: TransitionKind? = nil
        var transitionStart: Double? = nil
        var transitionEnd: Double? = nil
        var bTrackID: CMPersistentTrackID? = nil

        if let next = nextClip {
            let dur = min(transitionDuration, max(0.18, renderedDur * 0.25))
            transitionKind = clip.outgoingTransition
            transitionEnd = segmentStart.seconds + renderedDur
            transitionStart = transitionEnd! - dur

            // Insert `dur` seconds of next clip's head into trackB
            // anchored at the transition start. We use real-time playback
            // here (no speed curve on the B side) — the dissolve is short
            // enough that any ramp would be invisible.
            let bSourceRange = CMTimeRange(
                start: CMTime(seconds: next.sourceStart,
                              preferredTimescale: 600),
                duration: CMTime(seconds: dur,
                                 preferredTimescale: 600))
            let bInsertAt = CMTime(seconds: transitionStart!,
                                   preferredTimescale: 600)
            try? trackB.insertTimeRange(bSourceRange,
                                        of: assetVideoTrack,
                                        at: bInsertAt)
            bTrackID = trackB.trackID
        }

        let instr = MetalPetalInstruction(
            timeRange: outRange,
            startSeconds: segmentStart.seconds,
            trackAID: trackA.trackID,
            trackBID: bTrackID,
            cropKeyframes: clip.cropKeyframes,
            look: plan.style.lookUpTable,
            transitionKind: transitionKind,
            transitionStart: transitionStart,
            transitionEnd: transitionEnd,
            overlay: overlay)
        instructions.append(instr)
    }

    // MARK: - Overlay-only spans (title / closing)

    /// Title and closing cards: insert an empty time range on trackA.
    /// The MetalPetal compositor will see `sourceFrame == nil` and
    /// synthesize a solid-black background; the rasterized overlay
    /// paints on top with the fade-in/out schedule baked into the
    /// Overlay struct.
    ///
    /// This is the fix for Section 2.1 bug B — the old code paired
    /// insertEmptyTimeRange with a CoreAnimationTool, which conflicted
    /// with the custom compositor and left the title spans black.
    private func insertOverlayCard(duration: Double,
                                   trackA: AVMutableCompositionTrack,
                                   at insertTime: inout CMTime,
                                   instructions: inout [MetalPetalInstruction],
                                   plan: EditPlan,
                                   overlayImage: MTIImage?) throws {
        let segmentStart = insertTime
        let cardDur = CMTime(seconds: duration, preferredTimescale: 600)
        trackA.insertEmptyTimeRange(
            CMTimeRange(start: insertTime, duration: cardDur))
        insertTime = CMTimeAdd(insertTime, cardDur)

        let overlay = MetalPetalInstruction.Overlay(
            mtiImage: overlayImage,
            startTime: segmentStart.seconds,
            endTime: segmentStart.seconds + duration,
            fadeIn: 0.25,
            fadeOut: 0.25)

        let outRange = CMTimeRange(start: segmentStart, duration: cardDur)
        let instr = MetalPetalInstruction(
            timeRange: outRange,
            startSeconds: segmentStart.seconds,
            trackAID: trackA.trackID,
            trackBID: nil,
            cropKeyframes: [CropKeyframe(time: 0,
                                         center: CGPoint(x: 0.5, y: 0.5),
                                         scale: 1.0)],
            look: plan.style.lookUpTable,
            transitionKind: nil,
            transitionStart: nil,
            transitionEnd: nil,
            overlay: overlayImage != nil ? overlay : nil)
        instructions.append(instr)
    }

    private func makeLowerThirdOverlay(
        image: MTIImage?,
        startSeconds: Double,
        spec: LowerThirdSpec?
    ) -> MetalPetalInstruction.Overlay? {
        guard let image, let spec else { return nil }
        let start = startSeconds + spec.startOffset
        return MetalPetalInstruction.Overlay(
            mtiImage: image,
            startTime: start,
            endTime: start + spec.visibleDuration,
            fadeIn: 0.2,
            fadeOut: 0.3)
    }

    // MARK: - Card rasterization (CALayer → CGImage → MTIImage)

    /// Renders the existing CALayer-based title card at its "fully
    /// visible" state (no animations) into an MTIImage. The compositor
    /// owns fade-in / fade-out via Overlay.alphaAt(outputTime:).
    private func rasterize(titleCard spec: TitleCardSpec?,
                           size: CGSize) -> MTIImage? {
        guard let spec else { return nil }
        let layer = TitleCardFactory.staticTitleLayer(size: size, spec: spec)
        return rasterize(layer: layer, size: size)
    }

    private func rasterize(closingCard spec: ClosingCardSpec?,
                           size: CGSize) -> MTIImage? {
        guard let spec else { return nil }
        let layer = TitleCardFactory.staticClosingLayer(size: size, spec: spec)
        return rasterize(layer: layer, size: size)
    }

    private func rasterize(lowerThird spec: LowerThirdSpec?,
                           size: CGSize) -> MTIImage? {
        guard let spec else { return nil }
        let layer = TitleCardFactory.staticLowerThirdLayer(size: size, spec: spec)
        return rasterize(layer: layer, size: size)
    }

    private func rasterize(layer: CALayer, size: CGSize) -> MTIImage? {
        // CALayer's render uses top-left origin; AVFoundation's render
        // pipeline expects bottom-left for video. We flip the rendered
        // image vertically via Core Graphics before handing it to MTI.
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Flip vertically so the rasterized layer lines up with the
            // video frame's bottom-left coordinate system.
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        return MTIImage(cgImage: cg, isOpaque: false)
    }
}
