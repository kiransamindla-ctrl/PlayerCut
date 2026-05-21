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
        let videoDevice: AVCaptureDevice
        if let ultrawide = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                   for: .video,
                                                   position: .back) {
            videoDevice = ultrawide
            debugInfo.selectedCamera = "ultrawide"
            log.info("configure() video device: builtInUltraWideCamera")
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .back) {
            videoDevice = wide
            debugInfo.selectedCamera = "wide (no ultrawide)"
            log.info("configure() video device: builtInWideAngleCamera (no ultrawide)")
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

        // ── All session work runs sequentially on the serial queue ──
        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            session.sessionPreset = .inputPriority

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
                // Movie file output. We deliberately do NOT call
                // setOutputSettings here — that API throws an
                // uncatchable ObjC NSException ("avc1 is unsupported")
                // when the connection's available-codec list isn't yet
                // settled, which terminates this thread and prevents
                // session.startRunning() from ever being reached.
                // AVCaptureMovieFileOutput's default codec is HEVC
                // where supported (iOS 14+), H.264 otherwise — which
                // matches the recipe's preference on every device we
                // target (iPhone 13+, A15+).
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    if let conn = videoOutput.connection(with: .video) {
                        conn.preferredVideoStabilizationMode = .standard
                    }
                }

                // Audio loudness tap
                audioDataOutput.setSampleBufferDelegate(audioDelegate,
                                                       queue: audioQueue)
                if session.canAddOutput(audioDataOutput) {
                    session.addOutput(audioDataOutput)
                }

                // Diagnostic frame tap (verifies frames flow).
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
    /// without an actor hop). Sets activeFormat / locked fps / HDR off
    /// on the device, plus re-pins codec/stabilization on the movie
    /// output. Reports outcome to `debugInfo` via a MainActor hop.
    ///
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

        let (resolvedFormat, resolved) =
            DeviceCapabilities.resolveFormat(initial, on: device)
        guard let format = resolvedFormat else {
            log.warning("recipe: no AVCaptureDevice.Format satisfies any step-down — staying on device default")
            Task { @MainActor in
                debugInfo.recipeOutcome = "NO FORMAT (running on default)"
            }
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.activeFormat = format

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

            // Skip setOutputSettings — see comment in configure().
            // The movie output's default codec is HEVC where supported,
            // which is what we want; passing an explicit codec here
            // risks the uncatchable "avc1 is unsupported" NSException
            // when the connection's available list isn't yet settled.
            // Only the stabilization mode is set; that property doesn't
            // throw an NSException.
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

            log.info("recipe APPLIED: \(resolved.resolution.rawValue)@\(resolved.fps) (output uses default codec) stab=\(resolved.stabilization.rawValue, privacy: .public)")
            let outcome = "APPLIED \(resolved.resolution.rawValue)@\(resolved.fps) default-codec \(resolved.stabilization.rawValue)"
            Task { @MainActor [weak controller] in
                controller?.currentRecipe = resolved
                debugInfo.recipeOutcome = outcome
                await DiagnosticsStore.shared.recordEnum(
                    .captureSoCTier, value: tier)
                await DiagnosticsStore.shared.recordEnum(
                    .captureRecipeResolution, value: resolved.resolution)
            }
        } catch {
            log.error("recipe apply FAILED: \(error.localizedDescription)")
            let msg = error.localizedDescription
            Task { @MainActor in
                debugInfo.recipeOutcome = "FAILED: \(msg)"
            }
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
    /// mode, downgrading to `.standard` (or `.off`) when the requested
    /// mode isn't supported on this connection.
    private func stabilizationMode(
        for choice: CaptureRecipe.Stabilization,
        on connection: AVCaptureConnection
    ) -> AVCaptureVideoStabilizationMode {
        switch choice {
        case .off:        return .off
        case .standard:   return .standard
        case .cinematic:
            // Cinematic stabilization is hardware-gated. Fall back to
            // .standard rather than rejecting the configuration.
            if connection.isVideoStabilizationSupported {
                return .cinematic
            }
            return .standard
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
        sessionQueue.async {
            if !session.isRunning {
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .warning("startRecording: session not running, starting now")
                session.startRunning()
            }
            videoOutput.startRecording(to: videoURL, recordingDelegate: recordingDelegate)
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
        // Stop the file output + (eventually) the session on the
        // sessionQueue. Don't bother awaiting the stop — the delegate
        // signals completion via fileOutput(:didFinishRecordingTo:).
        let session = self._session
        let videoOutput = self.videoOutput
        sessionQueue.async {
            videoOutput.stopRecording()
            if session.isRunning {
                session.stopRunning()
            }
        }
        // Wait briefly for finalization.
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
