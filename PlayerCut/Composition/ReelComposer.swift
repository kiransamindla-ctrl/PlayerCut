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
    /// User-tunable reel knobs (game-audio toggle + levels, pacing, order).
    /// Read fresh from UserDefaults at compose() time by default; tests can
    /// override this on a per-instance basis.
    var settings: ReelSettings = .current
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
        var lastBodyOutputEnd: Double = 0   // drives the closing music fade
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

        // ─── Section 1: per-clip audio peak detection ────────────────
        // Drives the music duck + game-audio boost on the loudest 1–2 s of
        // each clip — the cheer / whistle / contact "hit" — rather than
        // guessing from the ranker's energy score. Skipped when the source
        // has no audio (sample-only test path) or the user has switched
        // off "Include game audio" in Settings.
        var clipPeaks: [UUID: Double] = [:]
        if settings.includeGameAudio, let assetAudioTrack {
            if let cold = plan.coldOpen,
               let p = await AudioPeakDetector.detectPeakOffset(
                in: assetAudioTrack,
                sourceStart: cold.sourceStart, sourceEnd: cold.sourceEnd) {
                clipPeaks[cold.id] = p
            }
            for clip in plan.body {
                if let p = await AudioPeakDetector.detectPeakOffset(
                    in: assetAudioTrack,
                    sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd) {
                    clipPeaks[clip.id] = p
                }
            }
            let totalClips = plan.body.count + (plan.coldOpen == nil ? 0 : 1)
            log.info("Peak detection: \(clipPeaks.count)/\(totalClips) clips have a usable source peak")
        }

        do {
            // Cold open ----------------------------------------------------
            if let cold = plan.coldOpen {
                let coldStart = insertTime
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
                appendPeakBand(for: cold,
                               segmentStart: coldStart,
                               segmentEnd: insertTime,
                               peakSourceOffset: clipPeaks[cold.id],
                               into: &audioDuckRanges)
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
            for (i, clip) in plan.body.enumerated() {
                let isLast = (i == plan.body.count - 1)
                let next: ClipPlan? = isLast ? nil : plan.body[i + 1]
                // Lower-third overlay rides on the first body clip only.
                let overlay: MetalPetalInstruction.Overlay? = (i == 0
                    ? makeLowerThirdOverlay(image: lowerThirdImage,
                                            startSeconds: insertTime.seconds,
                                            spec: plan.lowerThird)
                    : nil)
                let clipStart = insertTime
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
                appendPeakBand(for: clip,
                               segmentStart: clipStart,
                               segmentEnd: insertTime,
                               peakSourceOffset: clipPeaks[clip.id],
                               into: &audioDuckRanges)
            }
            lastBodyOutputEnd = insertTime.seconds

            // Closing card --------------------------------------------------
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
        var musicInserted = false
        if let musicURL = plan.musicURL,
           let musicTrack {
            let music = AVURLAsset(url: musicURL)
            if let track = try? await music.loadTracks(
                withMediaType: .audio).first,
               let srcDur = try? await music.load(.duration) {
                // Only insert as much music as the track actually has — a
                // 75 s bed under a 5-min reel would otherwise overrun the
                // source and throw. Loop-free: trim the range to min(total,
                // music length); the closing fade still lands at `total`.
                let useDur = CMTimeMinimum(totalDuration, srcDur)
                let range = CMTimeRange(start: .zero, duration: useDur)
                do {
                    try musicTrack.insertTimeRange(range, of: track, at: .zero)
                    musicInserted = true
                } catch {
                    log.warning("Music insert failed (\(error.localizedDescription, privacy: .public)) — reel will be silent")
                }
            } else {
                log.warning("Music URL provided but no audio track found — reel will be silent")
            }
        }

        // Section 1: every reel knob (toggle + dB sliders + duck depth +
        // game-audio boost) comes from `settings`, refreshed per compose.
        let s = settings
        let musicLevel     = ReelSettings.linearGain(db: s.musicLevelDb)
        let musicDuckLevel = ReelSettings.linearGain(db: s.musicLevelDb - s.duckDepthDb)
        let gameLevel      = ReelSettings.linearGain(db: s.gameAudioLevelDb)
        let gamePeakLevel  = ReelSettings.linearGain(db: s.gameAudioLevelDb + s.gameAudioBoostDb)
        let total = totalDuration.seconds

        // Merge the peak bands once — used by BOTH the music duck and the
        // game-audio boost so they're in sync (music dips ↘ exactly when
        // game audio rises ↗). Merge anything within attack+release so the
        // emitter never has to clamp overlapping ramps.
        let musicDuckAttack = 0.35   // // SOURCE: broadcast duck envelopes
        let musicDuckRelease = 0.55  //          (250-500 ms attack, 500-900 ms release)
        let gameAttack = 0.25
        let gameRelease = 0.40
        let mergeWindow = max(musicDuckAttack + musicDuckRelease,
                              gameAttack + gameRelease)
        let sortedDucks = audioDuckRanges
            .map { (s: $0.start.seconds, e: $0.end.seconds) }
            .sorted { $0.s < $1.s }
        var mergedPeaks: [(s: Double, e: Double)] = []
        for d in sortedDucks {
            if var last = mergedPeaks.last,
               d.s <= last.e + mergeWindow {
                last.e = max(last.e, d.e)
                mergedPeaks[mergedPeaks.count - 1] = last
            } else {
                mergedPeaks.append(d)
            }
        }

        let mix = AVMutableAudioMix()

        // ─── Game audio: low bed + boost on each peak band ──────────────
        // Gated on includeGameAudio (Settings → Reel Audio) AND on the
        // source actually carrying audio (the sample test path may not).
        if s.includeGameAudio, let audioTrack, assetAudioTrack != nil {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(gameLevel, at: .zero)
            var ramps: [(start: Double, end: Double, from: Float, to: Float)] = []
            for m in mergedPeaks {
                ramps.append((m.s, m.s + gameAttack, gameLevel, gamePeakLevel))
                ramps.append((m.e, m.e + gameRelease, gamePeakLevel, gameLevel))
            }
            emitNonOverlappingRamps(ramps, total: total, onto: params)
            mix.inputParameters.append(params)
        }

        // ─── Music bed: duck on each peak band + always-on closing fade ──
        // Only built when music was actually inserted (ramps on an empty
        // track produce an invalid audio mix).
        if let musicTrack, musicInserted {
            let params = AVMutableAudioMixInputParameters(track: musicTrack)
            params.setVolume(musicLevel, at: .zero)
            var ramps: [(start: Double, end: Double, from: Float, to: Float)] = []
            for m in mergedPeaks {
                ramps.append((m.s, m.s + musicDuckAttack, musicLevel, musicDuckLevel))
                ramps.append((m.e, m.e + musicDuckRelease, musicDuckLevel, musicLevel))
            }
            ramps.append((max(0, lastBodyOutputEnd), total, musicLevel, 0))
            emitNonOverlappingRamps(ramps, total: total, onto: params)
            mix.inputParameters.append(params)
        }

        // ─── Stage: pre-export validator (Section 1, tempo-proof) ───
        // Final guarantee before export: instructions tile [.zero, total]
        // exactly, ≤2 video tracks, every audio track == video length.
        // Repairs in place rather than failing, so a bad beat-snap at ANY
        // tempo can never hand AVAssetExportSession an invalid composition
        // (-11841 "Operation Stopped").
        let validatedInstructions = repairForExport(
            composition: composition,
            instructions: instructions,
            totalDuration: totalDuration)
        videoComposition.instructions = validatedInstructions

        // Snapshot the assembled pieces for white-box regression tests.
        // References only — no copy, no behavior change.
        self.lastAssembled = AssembledComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: mix,
            totalDuration: totalDuration,
            instructions: validatedInstructions)

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
                // Log the EXACT failing values, never a generic message:
                // error domain/code/reason + the composition shape that was
                // handed to the exporter (so a -11841 is debuggable).
                let ns = session.error as NSError?
                let durs = validatedInstructions.map {
                    String(format: "%.3f", $0.timeRange.duration.seconds)
                }.joined(separator: ",")
                log.error("Export FAILED status=\(session.status.rawValue) error=\(ns?.domain ?? "nil", privacy: .public) code=\(ns?.code ?? 0) reason=\(ns?.localizedDescription ?? "nil", privacy: .public) | total=\(totalDuration.seconds, format: .fixed(precision: 3))s instr=\(validatedInstructions.count) durs=[\(durs, privacy: .public)]")
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

    // MARK: - Peak-driven duck/boost band (Section 1)

    /// Maps a clip's source-time peak offset into the corresponding output
    /// time and appends a ~1.2 s band centered on it. ReelComposer's mix
    /// step uses these bands to duck the music AND boost the game audio in
    /// the same instant, so cheer/whistle/contact actually pops instead of
    /// hiding under the bed.
    private func appendPeakBand(for clip: ClipPlan,
                                segmentStart: CMTime,
                                segmentEnd: CMTime,
                                peakSourceOffset: Double?,
                                into ranges: inout [CMTimeRange]) {
        guard let peakOff = peakSourceOffset else { return }
        let outputPeakOffset = outputOffsetMapping(sourceOffset: peakOff, in: clip)
        let outputPeak = segmentStart.seconds + outputPeakOffset
        let segStartSec = segmentStart.seconds
        let segEndSec = segmentEnd.seconds
        // 1.2 s band (-0.4 s lead-in, +0.8 s tail) clamped inside the clip.
        let bandStart = max(segStartSec, outputPeak - 0.4)
        let bandEnd = min(segEndSec, outputPeak + 0.8)
        guard bandEnd > bandStart + 0.1 else { return }
        ranges.append(CMTimeRange(
            start: CMTime(seconds: bandStart, preferredTimescale: 600),
            duration: CMTime(seconds: bandEnd - bandStart, preferredTimescale: 600)))
        log.info("Peak band clip \(clip.id.uuidString.prefix(8), privacy: .public): src \(peakOff, format: .fixed(precision: 2))s → out \(outputPeak, format: .fixed(precision: 2))s [\(bandStart, format: .fixed(precision: 2)), \(bandEnd, format: .fixed(precision: 2))]s")
    }

    /// Walks the clip's piecewise speed curve to convert a source-time
    /// offset (in [0, sourceDuration]) into an output-time offset relative
    /// to the clip's start in the rendered timeline.
    private func outputOffsetMapping(sourceOffset s: Double,
                                     in clip: ClipPlan) -> Double {
        let srcDur = clip.sourceDuration
        guard srcDur > 0 else { return 0 }
        var out = 0.0
        for seg in clip.speedCurve.segments {
            let segSrcStart = seg.sourceFractionStart * srcDur
            let segSrcEnd = seg.sourceFractionEnd * srcDur
            let segSrcLen = max(0, segSrcEnd - segSrcStart)
            if s >= segSrcEnd {
                out += segSrcLen / max(0.01, seg.factor)
                continue
            }
            let within = max(0, s - segSrcStart)
            out += within / max(0.01, seg.factor)
            return out
        }
        return out
    }

    /// Emits a list of (start, end, fromVol, toVol) ramps onto an
    /// AVMutableAudioMixInputParameters in strictly-ordered, clamped form
    /// so adjacent ramps NEVER overlap and never exceed [0, total]. This
    /// is the rule AVMutableAudioMixInputParameters throws on if violated.
    private func emitNonOverlappingRamps(
        _ ramps: [(start: Double, end: Double, from: Float, to: Float)],
        total: Double,
        onto params: AVMutableAudioMixInputParameters) {
        var cursor = 0.0
        for r in ramps.sorted(by: { $0.start < $1.start }) {
            let s = max(r.start, cursor)
            let e = min(r.end, total)
            guard e > s + 0.001 else { continue }
            params.setVolumeRamp(
                fromStartVolume: r.from,
                toEndVolume: r.to,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: s, preferredTimescale: 600),
                    duration: CMTime(seconds: e - s, preferredTimescale: 600)))
            cursor = e
        }
    }

    // MARK: - Pre-export validator (Section 1 — tempo-proof)

    /// Guarantees the composition is valid for AVAssetExportSession,
    /// REPAIRING rather than failing. Returns the (possibly re-tiled)
    /// instruction list and mutates audio tracks in place. Logs the EXACT
    /// offending values on any repair so a tempo regression is debuggable,
    /// never a generic message.
    private func repairForExport(composition: AVMutableComposition,
                                 instructions: [MetalPetalInstruction],
                                 totalDuration: CMTime) -> [MetalPetalInstruction] {
        // 1. ≤2 video tracks (A/B). Can't safely drop one; log loudly.
        let videoTracks = composition.tracks(withMediaType: .video)
        if videoTracks.count > 2 {
            log.error("Pre-export: \(videoTracks.count) video tracks (>2) — composition over-built")
        }

        // 2. Re-tile instructions into EXACT [.zero, total] contiguity:
        //    drop any zero-duration instruction, close any rounding gap,
        //    force the last instruction to end exactly at total.
        let sorted = instructions.sorted {
            CMTimeCompare($0.timeRange.start, $1.timeRange.start) < 0
        }
        var cursor = CMTime.zero
        var repaired: [MetalPetalInstruction] = []
        var didRepair = false
        for (i, ins) in sorted.enumerated() {
            let isLast = (i == sorted.count - 1)
            let desiredEnd = isLast
                ? totalDuration
                : CMTimeMinimum(CMTimeAdd(cursor, ins.timeRange.duration),
                                totalDuration)
            let dur = CMTimeSubtract(desiredEnd, cursor)
            guard dur.seconds > 0.0001 else {
                log.error("Pre-export: dropping zero/negative instruction \(i) (orig [\(ins.timeRange.start.seconds, format: .fixed(precision: 4)), \(ins.timeRange.end.seconds, format: .fixed(precision: 4))]s)")
                didRepair = true
                continue
            }
            let newRange = CMTimeRange(start: cursor, duration: dur)
            if newRange == ins.timeRange {
                repaired.append(ins)
            } else {
                didRepair = true
                log.error("Pre-export re-tile instr \(i): [\(ins.timeRange.start.seconds, format: .fixed(precision: 4)), \(ins.timeRange.end.seconds, format: .fixed(precision: 4))] → [\(cursor.seconds, format: .fixed(precision: 4)), \(desiredEnd.seconds, format: .fixed(precision: 4))]s")
                repaired.append(ins.reTiled(to: newRange, startSeconds: cursor.seconds))
            }
            cursor = desiredEnd
        }
        if !didRepair { repaired = instructions }

        // 3. Every inserted audio track must be EXACTLY `total` long — an
        //    A/V length mismatch is the other -11841 trigger. Trim if
        //    longer, pad with silence if shorter; leave empty tracks alone.
        for track in composition.tracks(withMediaType: .audio) {
            let d = track.timeRange.duration
            if CMTimeCompare(d, totalDuration) > 0 {
                track.removeTimeRange(
                    CMTimeRange(start: totalDuration,
                                duration: CMTimeSubtract(d, totalDuration)))
                log.error("Pre-export: trimmed audio track \(track.trackID) \(d.seconds, format: .fixed(precision: 3))s → \(totalDuration.seconds, format: .fixed(precision: 3))s")
            } else if d.seconds > 0.0001, CMTimeCompare(d, totalDuration) < 0 {
                track.insertEmptyTimeRange(
                    CMTimeRange(start: d, duration: CMTimeSubtract(totalDuration, d)))
                log.info("Pre-export: padded audio track \(track.trackID) \(d.seconds, format: .fixed(precision: 3))s → \(totalDuration.seconds, format: .fixed(precision: 3))s")
            }
        }

        log.info("Pre-export validator OK: \(repaired.count) instructions tile [0, \(totalDuration.seconds, format: .fixed(precision: 2))]s, ≤2 video tracks, audio matched (repaired=\(didRepair))")
        return repaired
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

        // Section 2: apex freeze. Tier-A heroes hold their last frame for
        // freezeFrameSeconds before the cut — common pro effect. Insert a
        // single source frame at clip.sourceEnd and scale it up to that
        // duration. Game audio for the freeze is intentionally silent (we
        // skip the audio re-insert here) so the music dip + crowd peak
        // already in the speed-ramped tail aren't doubled up.
        if clip.freezeFrameSeconds > 0.01 {
            let frameSec = 1.0 / 30.0
            let frameStart = max(clip.sourceStart, clip.sourceEnd - frameSec)
            let frameRange = CMTimeRange(
                start: CMTime(seconds: frameStart, preferredTimescale: 600),
                duration: CMTime(seconds: frameSec, preferredTimescale: 600))
            try trackA.insertTimeRange(frameRange,
                                       of: assetVideoTrack,
                                       at: insertTime)
            let frameInserted = CMTimeRange(
                start: insertTime,
                duration: CMTime(seconds: frameSec, preferredTimescale: 600))
            let frozen = CMTime(seconds: clip.freezeFrameSeconds,
                                preferredTimescale: 600)
            trackA.scaleTimeRange(frameInserted, toDuration: frozen)
            insertTime = CMTimeAdd(insertTime, frozen)
        }

        // Use EXACT CMTime math for the instruction's time range: its end
        // must equal `insertTime` (the next clip's start) to the tick, so
        // instructions tile [.zero, total] with no gap/overlap. Rebuilding
        // the duration from `renderedDur` seconds at timescale 600 (the old
        // path) could round a tick off `insertTime` and open a sub-frame
        // gap — exactly the kind of invalid composition that exports as
        // -11841 "Operation Stopped".
        let renderedDur = insertTime.seconds - segmentStart.seconds
        let outRange = CMTimeRange(start: segmentStart,
                                   duration: CMTimeSubtract(insertTime, segmentStart))

        // Build the per-clip transition spec. The B-track gets the head
        // of the *next* clip's source so the compositor can blend real
        // A and B frames during the window.
        var transitionKind: TransitionKind? = nil
        var transitionStart: Double? = nil
        var transitionEnd: Double? = nil
        var bTrackID: CMPersistentTrackID? = nil

        if let next = nextClip {
            let dur = min(transitionDuration, max(0.18, renderedDur * 0.25))
            let tEnd = segmentStart.seconds + renderedDur
            let tStart = tEnd - dur
            transitionKind = clip.outgoingTransition
            transitionEnd = tEnd
            transitionStart = tStart

            // Insert `dur` seconds of next clip's head into trackB
            // anchored at the transition start. We use real-time playback
            // here (no speed curve on the B side) — the dissolve is short
            // enough that any ramp would be invisible.
            let bSourceRange = CMTimeRange(
                start: CMTime(seconds: next.sourceStart,
                              preferredTimescale: 600),
                duration: CMTime(seconds: dur,
                                 preferredTimescale: 600))
            let bInsertAt = CMTime(seconds: tStart,
                                   preferredTimescale: 600)
            try? trackB.insertTimeRange(bSourceRange,
                                        of: assetVideoTrack,
                                        at: bInsertAt)
            bTrackID = trackB.trackID
        }

        // PR #11 S3+S4 — per-clip auto color match gain + opt-in particle
        // overlay are both per-clip fields on ClipPlan; the orchestrator
        // populates them after EditPlanBuilder.build returns. Default
        // identity gain + nil particles preserve the legacy render path.
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
            overlay: overlay,
            colorMatchGain: clip.colorMatchGain,
            particles: clip.particles)
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
        // The card layers position their sublayers in a BOTTOM-LEFT
        // coordinate space (authored for the old CoreAnimationTool path,
        // which renders bottom-left). UIGraphicsImageRenderer draws
        // top-left, and MTIImage(cgImage:) loads the bitmap upright (no
        // implicit flip — orientation defaults to .up). The previous
        // `scaleBy(1,-1)` context flip got the sublayer PLACEMENT right
        // but mirrored every rendered glyph, so the title/closing text
        // exported UPSIDE-DOWN.
        //
        // isGeometryFlipped reconciles the bottom-left sublayer placement
        // WITHOUT mirroring the rendered content — text stays upright and
        // lands in the same position the old flip produced.
        // Render the card layer straight into the (top-left) UIKit
        // context. MTIImage(cgImage:) loads the bitmap upright
        // (orientation defaults to .up) and the MetalPetal compositor
        // draws it in the same orientation as the source video frames, so
        // no flip is needed. The old `scaleBy(1,-1)` context flip mirrored
        // every glyph and exported the title/closing text UPSIDE-DOWN
        // (device bug). Verified upright via TitleFrameTests
        // (Documents/title-frame.png on the sim). // SOURCE: verified by
        // frame extraction on iPhone 17 sim 2026-05-25.
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        return MTIImage(cgImage: cg, isOpaque: false)
    }
}
