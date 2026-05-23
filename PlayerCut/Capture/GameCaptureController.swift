//
//  GameCaptureController.swift
//  PlayerCut
//
//  Records 1080p30 HEVC video plus a low-overhead audio-loudness sidecar
//  used by Stage 1 for cheap event detection.
//

import AVFoundation
import Accelerate
import Foundation
import UIKit
import os.log

@MainActor
final class GameCaptureController: NSObject {

    private let log = Logger(subsystem: "com.playercut.app", category: "Capture")

    private let _session = AVCaptureSession()
    /// Read-only handle so a SwiftUI preview layer can attach. Don't mutate
    /// the session from outside — that's the controller's job.
    var session: AVCaptureSession { _session }
    private let videoOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    /// Diagnostic frame tap. Verifies the AV pipeline is actually
    /// producing frames — `session.isRunning == true` alone is a known
    /// false-positive (developer.apple.com/forums/thread/811759).
    private let frameTapOutput = AVCaptureVideoDataOutput()
    private let frameTapQueue = DispatchQueue(label: "playercut.frameTap")

    // ── Experimental AVAssetWriter recording path (Section 2) ──
    // Gated by WriterCaptureFlag.isEnabled (default OFF). When the
    // flag is ON we use writerVideoOutput + WriterRecordingPipeline
    // instead of `videoOutput` (AVCaptureMovieFileOutput) for the
    // recording. The legacy path is left intact and is still the
    // production default until on-device side-by-side verification.
    private let writerVideoOutput = AVCaptureVideoDataOutput()
    private let writerVideoQueue = DispatchQueue(label: "playercut.writer.video")
    private let writerAudioFanoutQueue = DispatchQueue(label: "playercut.writer.audio.fanout")
    private let writerVideoDelegate = WriterVideoDelegate()
    private let writerAudioDelegate = WriterAudioDelegate()
    private var writerPipeline: WriterRecordingPipeline?

    /// THE serial queue. Per Apple's AVCam sample and the AVFoundation
    /// engineer guidance on developer.apple.com/forums/thread/792147:
    /// every touch of AVCaptureSession, its inputs/outputs/connections,
    /// and the underlying AVCaptureDevice MUST happen on this single
    /// serial queue. Concurrent dispatches collide and strand
    /// startRunning() — exactly the preview-black bug we just diagnosed.
    private let sessionQueue = DispatchQueue(label: "com.playercut.sessionQueue")

    private let audioQueue = DispatchQueue(label: "playercut.audio.loudness")
    private var loudnessSamples: [LoudnessSample] = []
    private var loudnessSampleCounter = 0

    /// Cached so startRecording can re-lock white balance with scene-
    /// specific params after the luminance pre-flight.
    private var videoDevice: AVCaptureDevice?

    /// We sample loudness at 5 Hz (every 6th audio buffer at 30 Hz delivery).
    private let loudnessDownsample = 6

    private var currentSession: GameSession?

    /// Recipe the capture session is currently configured to. Set by
    /// `configure()` (initial selection) and `reconfigure(to:)` (live
    /// thermal/battery downgrade).
    private(set) var currentRecipe: CaptureRecipe?

    /// SoC tier we resolved at configure() — held so live downgrade can
    /// re-derive an updated recipe against the same hardware without
    /// re-reading utsname.
    private var socTier: SoCTier = .unknown

    /// Live system observers. Removed in deinit. Empty until configure()
    /// runs — we install observers there so capture-only consumers of
    /// this class don't pay the cost.
    private var systemObservers: [NSObjectProtocol] = []

    /// TEMPORARY diagnostic. Populated at the configure() / start /
    /// watchdog / runtime-error points so the on-screen overlay can
    /// display the values to a user who can't read Console.app.
    let debugInfo = CaptureDebugInfo()

    struct LoudnessSample: Codable {
        let t: Double      // seconds since recording start
        let rms: Float     // 0..1
    }

    deinit {
        for token in systemObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Setup (Apple AVCam serial-queue pattern)
    //
    // Everything that touches the session, its inputs/outputs, or the
    // underlying AVCaptureDevice runs SEQUENTIALLY on `sessionQueue`.
    // Order inside that single async block:
    //
    //   a. session.beginConfiguration()
    //   b. add video input, audio input, movie output, audio tap, frame tap
    //   c. session.commitConfiguration()
    //   d. apply the capture recipe (device.lockForConfiguration ↔ unlock)
    //   e. session.startRunning()
    //
    // Because sessionQueue is a serial queue, these can never overlap;
    // startRunning() is therefore never called between a
    // beginConfiguration/commitConfiguration pair, and the recipe's
    // device-config block can never race a concurrent startRunning.
    //
    // The AVCaptureVideoPreviewLayer's `session` is set elsewhere
    // (CameraPreviewView.makeUIView) — Apple's documented exception
    // that does not require the sessionQueue.

    func configure() throws {
        log.info("configure() start")
        debugInfo.configureStarted = true
        debugInfo.observeRuntimeErrors(on: session)
        debugInfo.firstFrameDelegate.debugInfo = debugInfo
        // B3: pin the audio session to .playAndRecord. Synchronous,
        // doesn't touch AVCaptureSession.
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord,
                                  mode: .videoRecording,
                                  options: [.mixWithOthers,
                                            .defaultToSpeaker,
                                            .allowBluetooth])
            try audio.setActive(true,
                                options: .notifyOthersOnDeactivation)
            log.info("configure() audio session pinned to playAndRecord")
        } catch {
            log.warning("AVAudioSession config failed: \(error.localizedDescription)")
        }
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Pick the AVCaptureDevice synchronously on the main actor so
        // we can stash it and pass it to the sessionQueue block.
        //
        // PRIMARY = builtInWideAngleCamera. The ultrawide on A15
        // (iPhone 13 / 14 / 14 Plus) cannot record 4K60 via
        // AVCaptureMovieFileOutput — preview works, but the file
        // output errors with -11872 "Cannot Record" / FigCaptureSource
        // -17281. The wide-angle camera on the same SoC reliably
        // records 4K60 and 1080p60. The ultrawide is retained ONLY
        // as a fallback in case wide is somehow unavailable (in
        // practice never on a back-camera iPhone).
        let videoDevice: AVCaptureDevice
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera,
                                              for: .video,
                                              position: .back) {
            videoDevice = wide
            debugInfo.selectedCamera = "wide"
            log.info("configure() video device: builtInWideAngleCamera (PRIMARY)")
        } else if let ultrawide = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                          for: .video,
                                                          position: .back) {
            videoDevice = ultrawide
            debugInfo.selectedCamera = "ultrawide (fallback, no wide!?)"
            log.info("configure() video device: builtInUltraWideCamera (fallback)")
        } else {
            debugInfo.selectedCamera = "(none)"
            throw PipelineError.captureFailed("No back camera available")
        }
        self.videoDevice = videoDevice
        observeThermalAndBattery()

        // Capture-by-value the references the closure needs. The session
        // and the output objects are reference types whose identity is
        // stable; capturing them here avoids touching @MainActor `self.*`
        // from the background queue.
        let session = self._session
        let videoOutput = self.videoOutput
        let audioDataOutput = self.audioDataOutput
        let frameTapOutput = self.frameTapOutput
        let frameTapDelegate = self.debugInfo.firstFrameDelegate
        let audioQueue = self.audioQueue
        let frameTapQueue = self.frameTapQueue
        let debugInfo = self.debugInfo
        let audioDelegate: AVCaptureAudioDataOutputSampleBufferDelegate = self
        // Writer path captures (Section 2). Captured here even when
        // the flag is off so the closure doesn't have to touch self.
        let writerVideoOutput = self.writerVideoOutput
        let writerVideoQueue = self.writerVideoQueue
        let writerAudioFanoutQueue = self.writerAudioFanoutQueue
        let writerVideoDelegate = self.writerVideoDelegate
        let writerAudioDelegate = self.writerAudioDelegate

        // ── All session work runs sequentially on the serial queue ──
        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            session.sessionPreset = .inputPriority

            // P3 wide color (Section 1 of the quality build).
            // Apple's default `automaticallyConfiguresCaptureDeviceForWideColor`
            // overrides whatever we set on the device to sRGB, which is
            // what makes our capture look flatter than the stock Camera
            // app's P3. Disable the auto-configurator here; the actual
            // device.activeColorSpace = .P3_D65 assignment happens
            // inside applyRecipeOnSessionQueue once activeFormat is set
            // (a format's supportedColorSpaces only enumerates AFTER
            // it's selected).
            // // SOURCE: AVCaptureDevice.h header
            // // (github xybp888/iOS-SDKs); Apple Dev Forums 681431,
            // // accessed 2026-05-22.
            session.automaticallyConfiguresCaptureDeviceForWideColor = false

            var setupFailure: String?

            // a→b: video input
            do {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                } else {
                    setupFailure = "cannot add video input"
                }
            } catch {
                setupFailure = "video input init: \(error.localizedDescription)"
            }

            if setupFailure == nil, let audioDevice = AVCaptureDevice.default(for: .audio) {
                if let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
            }

            if setupFailure == nil {
                // ── Recording output: branch on WriterCaptureFlag ──
                // When the flag is ON the experimental
                // AVCaptureVideoDataOutput + WriterRecordingPipeline
                // path takes over; AVCaptureMovieFileOutput is
                // intentionally NOT added (it would duplicate the
                // recording and starve the writer of bandwidth).
                let writerPath = WriterCaptureFlag.isEnabled
                if writerPath {
                    // Writer pipeline owns the recording. We need a
                    // full-res sample-buffer feed; the BGRA32
                    // pixel format gives the writer the cleanest
                    // signal and is what AVAssetWriter's HEVC encoder
                    // expects.
                    writerVideoOutput.alwaysDiscardsLateVideoFrames = false
                    writerVideoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            Int(kCVPixelFormatType_32BGRA)
                    ]
                    writerVideoOutput.setSampleBufferDelegate(
                        writerVideoDelegate,
                        queue: writerVideoQueue)
                    if session.canAddOutput(writerVideoOutput) {
                        session.addOutput(writerVideoOutput)
                        if let conn = writerVideoOutput
                            .connection(with: .video) {
                            // Stabilization: walked by stabilizationMode()
                            // (Section 3) when applyRecipe re-pins.
                            conn.preferredVideoStabilizationMode = .standard
                        }
                    }
                } else {
                    // Legacy AVCaptureMovieFileOutput. Default codec
                    // (HEVC on iOS 14+) is intentional — see the
                    // setOutputSettings NSException commit body for
                    // why we don't pin it explicitly.
                    if session.canAddOutput(videoOutput) {
                        session.addOutput(videoOutput)
                        if let conn = videoOutput.connection(with: .video) {
                            conn.preferredVideoStabilizationMode = .standard
                        }
                    }
                }

                // Audio tap. Always added, but the delegate target
                // depends on whether the writer path is active:
                //   flag OFF → loudness delegate (`audioDelegate`,
                //              which is GameCaptureController itself)
                //   flag ON  → writer fan-out (writerAudioDelegate),
                //              which forwards into the writer AND
                //              into the loudness delegate so the
                //              sidecar still gets samples.
                if writerPath {
                    writerAudioDelegate.loudnessDelegate = audioDelegate
                    audioDataOutput.setSampleBufferDelegate(
                        writerAudioDelegate,
                        queue: writerAudioFanoutQueue)
                } else {
                    audioDataOutput.setSampleBufferDelegate(
                        audioDelegate,
                        queue: audioQueue)
                }
                if session.canAddOutput(audioDataOutput) {
                    session.addOutput(audioDataOutput)
                }

                // Diagnostic frame tap (verifies frames flow). Kept
                // on both paths so the on-screen overlay's FRAME row
                // updates regardless.
                frameTapOutput.alwaysDiscardsLateVideoFrames = true
                frameTapOutput.setSampleBufferDelegate(frameTapDelegate,
                                                      queue: frameTapQueue)
                if session.canAddOutput(frameTapOutput) {
                    session.addOutput(frameTapOutput)
                }
            }

            // c: commit
            session.commitConfiguration()
            if let failure = setupFailure {
                Task { @MainActor [weak self] in
                    self?.debugInfo.recipeOutcome = "FAILED setup: \(failure)"
                }
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .error("session setup failed: \(failure, privacy: .public)")
                return
            }

            // d: apply recipe (device hardware config). Runs on this
            // same serial queue → cannot race a beginConfiguration block.
            // activeFormat is set on a not-yet-running session so no
            // session.beginConfiguration wrapper is required here.
            Self.applyRecipeOnSessionQueue(device: videoDevice,
                                           videoOutput: videoOutput,
                                           debugInfo: debugInfo,
                                           controller: self)

            // e: startRunning — strictly after commit and recipe.
            session.startRunning()
            let running = session.isRunning
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .info("startRunning() returned, isRunning=\(running)")
            Task { @MainActor [weak self] in
                self?.debugInfo.startRunningSawIsRunning = running
            }
        }

        debugInfo.configureReturned = true
        log.info("configure() returning — session setup dispatched to serial queue")
    }

    /// Recipe application body. RUNS ON sessionQueue (nonisolated so
    /// the caller can invoke it from inside the queue's async closure
    /// without an actor hop).
    ///
    /// Walks a step-down ladder of candidate (resolution, fps) pairs
    /// and stops at the first one that BOTH (a) exists as an
    /// AVCaptureDevice.Format on this device AND (b) reports a
    /// non-empty `videoOutput.availableVideoCodecTypes` after
    /// activeFormat assignment — Apple's available-codec list is the
    /// only API that exposes whether the movie file output will
    /// actually accept the chosen format for recording. The user's
    /// crash diagnosis showed that 4K60 on the ultrawide passes
    /// `resolveFormat` (the format exists) but produces -11872
    /// "Cannot Record" at recording time. With the wide camera now
    /// primary the ladder usually settles on the highest candidate;
    /// the loop is a safety net for any (device, format) combination
    /// the movie output refuses.
    ///
    /// Ladder (descending): 4K60 → 4K30 → 1080p60 → 1080p30. The
    /// device-state-driven downgrade in `DeviceCapabilities.liveRecipe`
    /// picks the starting point; the ladder only walks DOWN from there.
    /// Per the user's diagnosis: this MUST run after commitConfiguration
    /// and is NOT wrapped in another begin/commit — the session isn't
    /// running yet at this point, so activeFormat assignment doesn't
    /// need the wrapper.
    nonisolated private static func applyRecipeOnSessionQueue(
        device: AVCaptureDevice,
        videoOutput: AVCaptureMovieFileOutput,
        debugInfo: CaptureDebugInfo,
        controller: GameCaptureController?
    ) {
        let log = Logger(subsystem: "com.playercut.app", category: "Capture")
        let tier = DeviceCapabilities.currentTier()
        Task { @MainActor [weak controller] in
            controller?.socTier = tier
            debugInfo.resolvedTier = tier.rawValue
        }
        let battery = UIDevice.current.batteryLevel
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let initial = DeviceCapabilities.liveRecipe(
            for: tier,
            thermal: ProcessInfo.processInfo.thermalState,
            batteryLevel: battery,
            lowPower: lowPower)
        log.info("recipe: ideal=\(initial.resolution.rawValue)@\(initial.fps), tier=\(tier.rawValue, privacy: .public)")

        // Build the candidate ladder, descending from `initial`.
        //
        // HARD RULE — 4K REQUIRES HEVC. iOS does not support H.264 at
        // 4K resolution; trying to record produces error -11872
        // "Cannot Record" and the captured FigCaptureSourceRemote
        // -17281 the user reported.
        // // SOURCE: videoproc.com iphone-supported-video-formats
        // // (accessed 2026-01-30); captureguide.com iphone-video-format
        // // (accessed 2023-10-20).
        //
        // Therefore the ladder steps DOWN RESOLUTION before it ever
        // drops the codec:
        //
        //   HEVC 4K60 → HEVC 4K30 → HEVC 1080p60 → HEVC 1080p30
        //   → H.264 1080p60 → H.264 1080p30
        //
        // The H.264 rungs are ONLY 1080p. No H.264@4K, ever.
        let hevcLadder = stepDownLadder(from: initial)
        let h264Ladder = stepDownLadder(from: initial).filter {
            $0.resolution == .fhd1080
        }
        let ladderDesc = hevcLadder.map {
            "HEVC \($0.resolution.rawValue)@\($0.fps)"
        }.joined(separator: " → ")
        let h264Desc = h264Ladder.map {
            "H.264 \($0.resolution.rawValue)@\($0.fps)"
        }.joined(separator: " → ")
        log.info("recipe: ladder=\(ladderDesc, privacy: .public) → \(h264Desc, privacy: .public)")

        // Build a single combined ladder: HEVC at every rung, then
        // H.264 escape hatch at the 1080p rungs only.
        enum LadderRung {
            case hevc(CaptureRecipe)
            case h264Escape(CaptureRecipe)
            var recipe: CaptureRecipe {
                switch self {
                case .hevc(let r), .h264Escape(let r): return r
                }
            }
            var label: String {
                switch self {
                case .hevc(let r):
                    return "HEVC \(r.resolution.rawValue)@\(r.fps)"
                case .h264Escape(let r):
                    return "H.264 \(r.resolution.rawValue)@\(r.fps)"
                }
            }
        }
        let combined: [LadderRung] =
            hevcLadder.map { .hevc($0) } + h264Ladder.map { .h264Escape($0) }

        for (attempt, rung) in combined.enumerated() {
            let (resolvedFormat, resolved): (AVCaptureDevice.Format?,
                                             CaptureRecipe) = {
                switch rung {
                case .hevc(let r):
                    return DeviceCapabilities.resolveFormat(r, on: device)
                case .h264Escape(let r):
                    return DeviceCapabilities
                        .resolveFormatAllowingH264(r, on: device)
                }
            }()
            guard let format = resolvedFormat else {
                log.warning("recipe attempt \(attempt + 1) (\(rung.label, privacy: .public)): no format on this device — stepping down")
                continue
            }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = format
                // Wide color (Section 1) — the biggest stock-vs-PlayerCut
                // delta per the user's sourced root-cause analysis.
                // device.activeColorSpace defaults to sRGB when the
                // session's automaticallyConfiguresCaptureDeviceForWideColor
                // is true; we disabled that in configure(), now we
                // explicitly opt into P3_D65 when the format supports it.
                // // SOURCE: AVCaptureDevice.h header; Apple Dev Forums
                // // 681431, accessed 2026-05-22.
                let p3Supported = format.supportedColorSpaces
                    .contains(.P3_D65)
                if p3Supported {
                    device.activeColorSpace = .P3_D65
                } else {
                    device.activeColorSpace = .sRGB
                }
                let csLabel: String = {
                    switch device.activeColorSpace {
                    case .P3_D65:      return "P3_D65"
                    case .sRGB:        return "sRGB"
                    case .HLG_BT2020:  return "HLG_BT2020"
                    case .appleLog:    return "appleLog"
                    @unknown default:  return "(\(device.activeColorSpace.rawValue))"
                    }
                }()
                Task { @MainActor in
                    debugInfo.colorSpace = csLabel
                }
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .info("colorSpace: \(csLabel, privacy: .public) (p3 supported by format: \(p3Supported))")
                if format.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                device.activeVideoMinFrameDuration =
                    CMTime(value: 1, timescale: Int32(resolved.fps))
                device.activeVideoMaxFrameDuration =
                    CMTime(value: 1, timescale: Int32(resolved.fps))
            } catch {
                log.error("recipe attempt \(attempt + 1) (\(resolved.resolution.rawValue)@\(resolved.fps)): lockForConfig threw: \(error.localizedDescription) — stepping down")
                continue
            }

            // Recordability check: after activeFormat assignment, the
            // connection's available codec list is the cheapest synchronous
            // signal that the format is actually recordable. Empty list →
            // movie file output refuses; skip.
            let availableCodecs = videoOutput.availableVideoCodecTypes
            log.info("recipe attempt \(attempt + 1) (\(resolved.resolution.rawValue)@\(resolved.fps)): availableVideoCodecTypes=\(availableCodecs.map(\.rawValue).joined(separator: ","), privacy: .public)")
            guard !availableCodecs.isEmpty else {
                log.warning("recipe attempt \(attempt + 1): empty availableVideoCodecTypes → not recordable — stepping down")
                continue
            }

            // Recordable. Set stabilization, log, surface to overlay.
            if let conn = videoOutput.connection(with: .video) {
                conn.preferredVideoStabilizationMode = {
                    switch resolved.stabilization {
                    case .off:        return .off
                    case .standard:   return .standard
                    case .cinematic:
                        return conn.isVideoStabilizationSupported
                            ? .cinematic : .standard
                    }
                }()
            }
            log.info("recipe APPLIED on attempt \(attempt + 1) (\(rung.label, privacy: .public)): \(resolved.resolution.rawValue)@\(resolved.fps) codec=\(resolved.codec.rawValue, privacy: .public) stab=\(resolved.stabilization.rawValue, privacy: .public)")
            let outcome = "APPLIED \(resolved.resolution.rawValue)@\(resolved.fps) \(resolved.codec.rawValue) (try \(attempt + 1)) \(resolved.stabilization.rawValue)"
            Task { @MainActor [weak controller] in
                controller?.currentRecipe = resolved
                debugInfo.recipeOutcome = outcome
                await DiagnosticsStore.shared.recordEnum(
                    .captureSoCTier, value: tier)
                await DiagnosticsStore.shared.recordEnum(
                    .captureRecipeResolution, value: resolved.resolution)
            }
            return
        }

        // Ladder exhausted — leave device on its default format. The
        // session is already configured and will still start; just no
        // explicit recipe applied. Surface to the overlay.
        log.error("recipe: all ladder attempts failed — leaving device default; recording may use whatever the camera negotiates")
        Task { @MainActor in
            debugInfo.recipeOutcome = "NO RECORDABLE FORMAT (\(combined.count) attempts, on default)"
        }
    }

    /// Descending step-down candidates starting at `start`. The order
    /// is fixed and SoC-agnostic: 4K60 → 4K30 → 1080p60 → 1080p30.
    /// We only emit candidates that are equal-or-less demanding than
    /// `start` so the thermal/battery preconditioning in liveRecipe is
    /// honored.
    nonisolated private static func stepDownLadder(
        from start: CaptureRecipe
    ) -> [CaptureRecipe] {
        let allRungs: [(CaptureRecipe.Resolution, Int)] = [
            (.uhd4k, 60), (.uhd4k, 30),
            (.fhd1080, 60), (.fhd1080, 30)
        ]
        // Find the index of the highest rung that doesn't exceed `start`.
        let startRank: (Int, Int) = {
            let r = start.resolution == .uhd4k ? 1 : 0
            return (r, start.fps)
        }()
        return allRungs.compactMap { (res, fps) -> CaptureRecipe? in
            let r = res == .uhd4k ? 1 : 0
            // Skip rungs that exceed start.
            if r > startRank.0 { return nil }
            if r == startRank.0 && fps > startRank.1 { return nil }
            return CaptureRecipe(resolution: res, fps: fps,
                                 codec: start.codec,
                                 stabilization: start.stabilization)
        }
    }

    /// Returns a short description of the current videoDevice's
    /// activeFormat (dimensions + max fps + media subtype four-char-code)
    /// suitable for the diagnostic overlay. "(no device)" when configure
    /// hasn't run yet.
    func currentActiveFormatDescription() -> String {
        guard let device = videoDevice else { return "(no device)" }
        let f = device.activeFormat
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        // Decode 'hvc1' / '420v' / etc. to its character form.
        let chars = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >>  8) & 0xFF),
            UInt8( subtype        & 0xFF)
        ]
        let subtypeStr = String(bytes: chars, encoding: .ascii) ?? "????"
        let maxFps = f.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max() ?? 0
        return "\(d.width)x\(d.height) @\(Int(maxFps)) \(subtypeStr)"
    }

    /// External watchdog hook: if the preview hasn't gone live within
    /// the UI's grace period, force-start the session again and log.
    /// Dispatches through `sessionQueue` per Apple's pattern — never
    /// through DispatchQueue.global(), which can collide with the
    /// configure() session block.
    func forceRestartIfStalled() {
        let session = self._session
        let debugInfo = self.debugInfo
        sessionQueue.async {
            if session.isRunning {
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .info("watchdog: session already running, no-op")
                Task { @MainActor in
                    debugInfo.watchdogSawIsRunning = true
                }
                return
            }
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .error("watchdog: session NOT running — force-starting on sessionQueue")
            Task { @MainActor in
                debugInfo.watchdogSawIsRunning = false
                debugInfo.watchdogForcedRestart = true
            }
            session.startRunning()
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .info("watchdog: after force-start, isRunning=\(session.isRunning)")
        }
    }

    // MARK: - Recipe application

    /// Applies a recipe to the camera device: activeFormat, locked
    /// fps, locked focus/exposure/WB, HDR explicitly off. Caller owns
    /// session.beginConfiguration / commitConfiguration.
    private func applyRecipe(_ recipe: CaptureRecipe,
                             format: AVCaptureDevice.Format,
                             to device: AVCaptureDevice,
                             scene: SceneType) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // activeFormat must be set before fps lock; iOS rejects the
        // frame-duration write otherwise.
        device.activeFormat = format

        // HDR and Dolby Vision: explicitly disabled.
        // Crunchy/oversaturated for sports + breaks non-Apple sharing.
        // SOURCE: shopmoment.com/journal/best-iphone-camera-settings
        // (accessed 2026-01-22).
        if format.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }

        // Lock focus / exposure / WB (existing scene-aware logic).
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            switch scene {
            case .indoor:
                let target = AVCaptureDevice
                    .WhiteBalanceTemperatureAndTintValues(temperature: 4000,
                                                          tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: target)
                gains = Self.clampGains(gains,
                                        max: device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: gains) { _ in }
            case .outdoor:
                device.whiteBalanceMode = .locked
            }
        }

        // Lock fps at the recipe value.
        device.activeVideoMinFrameDuration =
            CMTime(value: 1, timescale: Int32(recipe.fps))
        device.activeVideoMaxFrameDuration =
            CMTime(value: 1, timescale: Int32(recipe.fps))
    }

    /// Maps the recipe's stabilization choice to a real AVFoundation
    /// mode, downgrading gracefully when the chosen connection doesn't
    /// support the requested mode at the current activeFormat.
    ///
    /// Cinematic-tier request walks: .cinematicExtended → .cinematic
    /// → .standard, picking the first the connection accepts. The
    /// extended variant gives slightly more aggressive smoothing on
    /// iPhone 13+; .cinematic is the broadcast-grade default. Both
    /// produce the "Trace/Veo smooth pan" look that's the visible
    /// distinguishing feature vs. raw handheld footage.
    /// // SOURCE: Apple AVCaptureVideoStabilizationMode docs.
    private func stabilizationMode(
        for choice: CaptureRecipe.Stabilization,
        on connection: AVCaptureConnection
    ) -> AVCaptureVideoStabilizationMode {
        switch choice {
        case .off:        return .off
        case .standard:
            if connection.isVideoStabilizationSupported {
                return .standard
            }
            return .off
        case .cinematic:
            // Walk the preferred ladder: extended → cinematic → standard.
            if connection.isVideoStabilizationSupported {
                // Per-mode probe via AVCaptureDevice.Format API isn't
                // exposed on AVCaptureConnection in iOS 17+; we trust
                // the general isVideoStabilizationSupported and let
                // AVFoundation pick a sensible value from the modes the
                // active format supports when we assign .cinematic.
                // If the assignment is silently downgraded, the camera
                // still records — just with slightly less smoothing.
                return .cinematic
            }
            return .off
        }
    }

    // MARK: - Live downgrade (thermal + battery)

    /// Subscribes to thermal-state and battery-level changes. On a
    /// transition that would warrant a recipe step-down we
    /// reconfigure the active device live where AVFoundation allows
    /// it. Downgrades are one-way for the current session — we never
    /// upgrade mid-game (would yank focus / WB).
    private func observeThermalAndBattery() {
        // Thermal.
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateDowngrade(trigger: .thermal)
                }
            })
        // Battery level. UIDevice posts changes when the level crosses
        // a 5 % boundary (system-defined) — fine grain for our 20/10 %
        // thresholds.
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateDowngrade(trigger: .battery)
                }
            })
        // Low-power mode toggles are equivalent to "battery is now
        // constrained" in our ladder.
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateDowngrade(trigger: .battery)
                }
            })
    }

    private enum DowngradeTrigger {
        case thermal, battery
    }

    /// Re-derives the recipe under current state and applies it if it
    /// has strictly dropped from the active one. No-op if the active
    /// recipe still satisfies the ladder.
    ///
    /// Unlike configure(), the session is ALREADY running when a live
    /// downgrade fires. Per Apple's docs, changing `activeFormat` on a
    /// running session requires a beginConfiguration/commitConfiguration
    /// pair around the change. Both happen on `sessionQueue` so they
    /// can't race anything else.
    private func evaluateDowngrade(trigger: DowngradeTrigger) {
        guard let active = currentRecipe,
              let device = videoDevice else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        let battery = UIDevice.current.batteryLevel
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let target = DeviceCapabilities.downgrade(
            active,
            for: thermal,
            batteryLevel: battery,
            lowPower: lowPower)
        guard target != active, isStrictlyLower(target, than: active) else {
            return
        }
        let (resolvedFormat, resolvedRecipe) =
            DeviceCapabilities.resolveFormat(target, on: device)
        guard let format = resolvedFormat else {
            log.warning("Downgrade target has no supported format; staying at \(active.resolution.rawValue)@\(active.fps)")
            return
        }
        let fromDesc = "\(active.resolution.rawValue)@\(active.fps)"
        let toDesc   = "\(resolvedRecipe.resolution.rawValue)@\(resolvedRecipe.fps)"

        let session = self._session
        sessionQueue.async { [weak self] in
            do {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = format
                device.activeVideoMinFrameDuration =
                    CMTime(value: 1, timescale: Int32(resolvedRecipe.fps))
                device.activeVideoMaxFrameDuration =
                    CMTime(value: 1, timescale: Int32(resolvedRecipe.fps))
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .info("downgrade applied on sessionQueue: \(fromDesc, privacy: .public) → \(toDesc, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.currentRecipe = resolvedRecipe
                    if var live = self?.currentSession {
                        live.captureRecipe = resolvedRecipe
                        self?.currentSession = live
                    }
                    switch trigger {
                    case .thermal:
                        await DiagnosticsStore.shared
                            .increment(.captureDowngradeThermal)
                    case .battery:
                        await DiagnosticsStore.shared
                            .increment(.captureDowngradeBattery)
                    }
                }
            } catch {
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .error("downgrade reconfigure failed: \(error.localizedDescription)")
            }
        }
    }

    /// True when `target` is unambiguously a less-demanding recipe
    /// than `current`. Compares (resolution, fps) — codec/stabilization
    /// shifts alone don't count as a downgrade.
    private func isStrictlyLower(_ target: CaptureRecipe,
                                 than current: CaptureRecipe) -> Bool {
        // resolution rank: 4K > 1080p
        let curRes = current.resolution == .uhd4k ? 1 : 0
        let tgtRes = target.resolution == .uhd4k ? 1 : 0
        if tgtRes < curRes { return true }
        if tgtRes == curRes && target.fps < current.fps { return true }
        // same resolution + same fps, but stab dropped from cinematic.
        if tgtRes == curRes
            && target.fps == current.fps
            && current.stabilization == .cinematic
            && target.stabilization != .cinematic {
            return true
        }
        return false
    }

    private static func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                   max maxGain: Float)
        -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ g: Float) -> Float { min(max(1.0, g), maxGain) }
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: clamp(gains.redGain),
            greenGain: clamp(gains.greenGain),
            blueGain: clamp(gains.blueGain))
    }

    // MARK: - Scene detection (pre-flight luminance sample)

    /// One-shot pre-flight: taps a single video frame from the already-
    /// running session, returns `.indoor` if mean Y-plane luminance is
    /// below 0.3 (gym/practice room), `.outdoor` otherwise. Times out
    /// at 2 s with `.outdoor` so a misbehaving device never blocks
    /// recording start.
    ///
    /// The session is configured + started by configure(); we add a
    /// temporary AVCaptureVideoDataOutput on `sessionQueue` so the
    /// add/remove can't race with anything.
    private func sampleSceneType() async -> SceneType {
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        let delegate = SceneLuminanceDelegate()
        let queue = DispatchQueue(label: "playercut.scene.detect")
        dataOutput.setSampleBufferDelegate(delegate, queue: queue)

        let session = self._session
        // Add the data output on the serial sessionQueue.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                session.beginConfiguration()
                if session.canAddOutput(dataOutput) {
                    session.addOutput(dataOutput)
                }
                session.commitConfiguration()
                cont.resume()
            }
        }

        let luminance = await delegate.firstLuminance(timeoutSeconds: 2.0)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                session.beginConfiguration()
                session.removeOutput(dataOutput)
                session.commitConfiguration()
                cont.resume()
            }
        }

        guard let lum = luminance else {
            log.warning("Scene detect: timed out, defaulting outdoor")
            return .outdoor
        }
        let scene: SceneType = lum < 0.3 ? .indoor : .outdoor
        log.info("Scene detect: luminance=\(lum, format: .fixed(precision: 3)) → \(scene.rawValue)")
        return scene
    }

    // MARK: - Lifecycle

    func startRecording(for player: PlayerEnrollment,
                        sport: Sport,
                        triggerSource: TriggerSource = .manual,
                        reelLengthOverride: ReelLength? = nil) async throws -> GameSession {
        let id = UUID()
        // Raw recording is ephemeral under the zero-video-storage policy.
        // The orchestrator deletes both these files once the reel is in
        // the Photos library.
        let dir = StoragePaths.tempGameDirectory(for: id)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let videoURL = StoragePaths.tempRawVideoURL(for: id)
        let audioURL = StoragePaths.tempAudioLoudnessURL(for: id)

        loudnessSamples.removeAll(keepingCapacity: true)
        loudnessSampleCounter = 0

        // Pre-flight: detect scene + re-lock WB with scene-appropriate
        // params before the actual recording starts. Defaults outdoor on
        // any failure so we never block the user from recording.
        let scene = await sampleSceneType()
        // Re-lock the scene-aware WB on sessionQueue (device hardware
        // config, must be on the same serial queue as all other
        // device.lockForConfiguration callers).
        if let device = videoDevice, let recipe = currentRecipe {
            let session = self._session
            sessionQueue.async {
                guard session.isRunning else { return }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.isWhiteBalanceModeSupported(.locked) {
                        switch scene {
                        case .indoor:
                            let target = AVCaptureDevice
                                .WhiteBalanceTemperatureAndTintValues(
                                    temperature: 4000, tint: 0)
                            var gains = device.deviceWhiteBalanceGains(for: target)
                            gains = Self.clampGains(gains,
                                                    max: device.maxWhiteBalanceGain)
                            device.setWhiteBalanceModeLocked(with: gains) { _ in }
                        case .outdoor:
                            device.whiteBalanceMode = .locked
                        }
                    }
                    _ = recipe // referenced for future scene-aware re-tunes
                } catch {
                    Logger(subsystem: "com.playercut.app", category: "Capture")
                        .error("scene WB re-lock failed: \(error.localizedDescription)")
                }
            }
        }

        // startRunning has already been called by configure(); if for
        // any reason it isn't running, kick it back via sessionQueue.
        let session = self._session
        let videoOutput = self.videoOutput
        let recordingDelegate: AVCaptureFileOutputRecordingDelegate = self
        let writerPath = WriterCaptureFlag.isEnabled
        // Writer-path bitrate scales with capture resolution. The
        // values come from the spec (Section 2): ~45 Mbps for 4K,
        // ~25 Mbps for 1080p HEVC — matches stock-Camera rates.
        let writerBitRate: Int = {
            switch currentRecipe?.resolution {
            case .uhd4k:   return 45_000_000
            default:       return 25_000_000
            }
        }()
        let writerVideoSize: CGSize = {
            guard let device = videoDevice else {
                return CGSize(width: 1920, height: 1080)
            }
            let d = CMVideoFormatDescriptionGetDimensions(
                device.activeFormat.formatDescription)
            return CGSize(width: CGFloat(d.width),
                          height: CGFloat(d.height))
        }()
        if writerPath {
            let pipeline = WriterRecordingPipeline(
                outputURL: videoURL,
                settings: .init(videoSize: writerVideoSize,
                                videoBitRate: writerBitRate))
            self.writerPipeline = pipeline
            self.writerVideoDelegate.pipeline = pipeline
            self.writerAudioDelegate.pipeline = pipeline
            self.log.info("WRITER path: target \(Int(writerVideoSize.width))×\(Int(writerVideoSize.height)) HEVC @ \(writerBitRate / 1_000_000) Mbps")
        }
        sessionQueue.async {
            if !session.isRunning {
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .warning("startRecording: session not running, starting now")
                session.startRunning()
            }
            if !writerPath {
                videoOutput.startRecording(to: videoURL,
                                           recordingDelegate: recordingDelegate)
            }
            // Writer path needs no start call here — the pipeline
            // is now wired as the delegate target on the writer's
            // video + audio outputs and starts on first sample.
        }

        let game = GameSession(id: id,
                               playerId: player.id,
                               sport: sport,
                               startedAt: Date(),
                               endedAt: nil,
                               rawVideoURL: videoURL,
                               audioLoudnessURL: audioURL,
                               stage1Result: nil,
                               stage2Result: nil,
                               exportedReelAssetId: nil,
                               localReelFallbackURL: nil,
                               status: .recording,
                               triggerSource: triggerSource,
                               reelLengthOverride: reelLengthOverride,
                               sceneType: scene,
                               captureRecipe: currentRecipe)
        currentSession = game
        log.info("Recording started: \(id.uuidString) trigger=\(triggerSource.rawValue) scene=\(scene.rawValue) recipe=\(self.currentRecipe?.resolution.rawValue ?? "?")@\(self.currentRecipe?.fps ?? 0)")
        return game
    }

    func stopRecording() async throws -> GameSession {
        guard var game = currentSession else {
            throw PipelineError.captureFailed("No active session")
        }
        let session = self._session
        let videoOutput = self.videoOutput
        // Writer path: tell the writer pipeline to finalize FIRST
        // (so we don't stop the session out from under in-flight
        // sample buffers), then stop the session.
        // Legacy path: AVCaptureMovieFileOutput's stopRecording is
        // async via the file-output delegate; we just stop it and
        // let the brief Task.sleep below cover finalization.
        if let pipeline = writerPipeline {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pipeline.finish { result in
                    switch result {
                    case .success(let url):
                        Logger(subsystem: "com.playercut.app", category: "Capture")
                            .info("writer finished: \(url.lastPathComponent, privacy: .public)")
                    case .failure(let err):
                        Logger(subsystem: "com.playercut.app", category: "Capture")
                            .error("writer finish failed: \(err.localizedDescription)")
                    }
                    cont.resume()
                }
            }
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
            }
            writerPipeline = nil
        } else {
            sessionQueue.async {
                videoOutput.stopRecording()
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }
        // Wait briefly for finalization (legacy path; writer already
        // awaited above).
        try await Task.sleep(nanoseconds: 300_000_000)

        // Write loudness sidecar
        let payload = try JSONEncoder().encode(loudnessSamples)
        try payload.write(to: game.audioLoudnessURL, options: .atomic)

        game.endedAt = Date()
        game.status = .awaitingProcessing
        currentSession = nil
        log.info("Recording stopped: \(game.id.uuidString), \(self.loudnessSamples.count) loudness samples")

        await DiagnosticsStore.shared.increment(.gamesRecorded)
        await DiagnosticsStore.shared.recordDuration(
            .captureSession,
            seconds: Date().timeIntervalSince(game.startedAt))

        return game
    }
}

// MARK: - File output delegate

extension GameCaptureController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        if let error {
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .error("Recording finished with error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Audio loudness tap

extension GameCaptureController: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        Task { @MainActor in
            self.processAudio(sampleBuffer)
        }
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        loudnessSampleCounter += 1
        guard loudnessSampleCounter % loudnessDownsample == 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        let sampleCount = totalLength / MemoryLayout<Int16>.size
        let samples = UnsafeBufferPointer(start: UnsafeRawPointer(dataPointer)
            .assumingMemoryBound(to: Int16.self),
                                          count: sampleCount)

        // Compute RMS using vDSP (fast)
        var floatBuffer = [Float](repeating: 0, count: sampleCount)
        vDSP_vflt16(samples.baseAddress!, 1, &floatBuffer, 1, vDSP_Length(sampleCount))
        var scale: Float = 1.0 / Float(Int16.max)
        vDSP_vsmul(floatBuffer, 1, &scale, &floatBuffer, 1, vDSP_Length(sampleCount))

        var rms: Float = 0
        vDSP_rmsqv(floatBuffer, 1, &rms, vDSP_Length(sampleCount))

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        loudnessSamples.append(LoudnessSample(t: presentationTime, rms: rms))
    }
}

// MARK: - Scene luminance delegate

/// Captures one frame from a temporary AVCaptureVideoDataOutput, computes
/// the mean Y-plane value, and resolves a single continuation with the
/// normalized [0, 1] luminance. Times out (resolves nil) so a stalled
/// capture device can never freeze recording start.
final class SceneLuminanceDelegate: NSObject,
                                    AVCaptureVideoDataOutputSampleBufferDelegate,
                                    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var resolved = false

    func firstLuminance(timeoutSeconds: TimeInterval) async -> Double? {
        await withCheckedContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutSeconds) { [weak self] in
                self?.resolve(nil)
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let lum = Self.meanLuminance(of: buffer)
        resolve(lum)
    }

    private func resolve(_ value: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// Averages the Y plane of a 420 YpCbCr buffer, subsampled 8× in
    /// each axis. ~32 k samples per frame is enough for a stable mean.
    private static func meanLuminance(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return 0.5
        }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var count: Int = 0
        for y in stride(from: 0, to: height, by: 8) {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 8) {
                sum &+= UInt64(row[x])
                count += 1
            }
        }
        guard count > 0 else { return 0.5 }
        return Double(sum) / Double(count) / 255.0
    }
}
