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

    // MARK: - Setup
    //
    // configure() is split into two phases on purpose:
    //
    //   PHASE 1 (must succeed if the camera exists) — audio session,
    //     video + audio inputs, file + audio-tap outputs, session
    //     commit, AND session.startRunning(). The preview goes LIVE
    //     here. This phase only throws if there is literally no usable
    //     camera; it does not depend on recipe selection.
    //
    //   PHASE 2 (best-effort) — apply the adaptive capture recipe
    //     (activeFormat + locked fps + HDR-off + locked WB). If any
    //     step fails we log loudly and leave the device on whatever
    //     default format AVFoundation picked from the session. The
    //     preview stays live; the user can still tap record.
    //
    // The previous code path threw out of Phase 1 if format selection
    // failed, which left the SwiftUI preview attached to a session
    // that was configured-but-never-started — black screen, frozen UI.

    func configure() throws {
        log.info("configure() start")
        debugInfo.configureStarted = true
        debugInfo.observeRuntimeErrors(on: session)
        // B3: pin the audio session to .playAndRecord for the duration
        // of the capture session. The default .ambient category would
        // be deactivated by AVCapture and re-activated on each output,
        // which causes glitchy loudness samples in the first second.
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

        // Battery monitoring has to be opted into before UIDevice will
        // report a real level. Cheap to enable; survives backgrounding.
        UIDevice.current.isBatteryMonitoringEnabled = true

        // ─── PHASE 1: inputs + outputs + session start ─────────────
        session.beginConfiguration()
        // sessionPreset .inputPriority lets a later device.activeFormat
        // assignment take effect; without it the preset wins and the
        // recipe is silently overridden. If we never set activeFormat
        // (Phase 2 fails), .inputPriority falls back to the device's
        // own default format, which still gives a usable preview.
        session.sessionPreset = .inputPriority
        log.info("configure() sessionPreset=inputPriority, beginConfiguration ok")

        // Video input — prefer the ultrawide on A12+ phones because it
        // captures more of the sideline at the same tripod distance.
        // Fall back to the standard wide if the device doesn't expose
        // an ultrawide (older models, or specific iPhone SEs).
        let videoDevice: AVCaptureDevice
        if let ultrawide = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                   for: .video,
                                                   position: .back) {
            videoDevice = ultrawide
            log.info("configure() video device: builtInUltraWideCamera")
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .back) {
            videoDevice = wide
            log.info("configure() video device: builtInWideAngleCamera (no ultrawide)")
        } else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("No back camera available")
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("Cannot add video input")
        }
        session.addInput(videoInput)
        log.info("configure() video input added")

        // Audio input
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("No audio device")
        }
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("Cannot add audio input")
        }
        session.addInput(audioInput)
        log.info("configure() audio input added")

        // Movie file output. Codec is HEVC by default; Phase 2 may
        // downgrade to H.264 if the recipe resolved that way.
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("Cannot add movie file output")
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            let chosenCodec: AVVideoCodecType =
                videoOutput.availableVideoCodecTypes.contains(.hevc)
                ? .hevc : .h264
            videoOutput.setOutputSettings(
                [AVVideoCodecKey: chosenCodec], for: connection)
            connection.preferredVideoStabilizationMode = .standard
        }
        log.info("configure() movie output added")

        // Audio data tap for loudness
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioDataOutput) else {
            session.commitConfiguration()
            throw PipelineError.captureFailed("Cannot add audio data output")
        }
        session.addOutput(audioDataOutput)
        log.info("configure() audio tap added")

        session.commitConfiguration()
        log.info("configure() commitConfiguration done")

        self.videoDevice = videoDevice

        // Start the session ON A BACKGROUND QUEUE per Apple's
        // recommendation. startRunning() blocks until the AV pipeline
        // is up; doing it from main can pause the SwiftUI render that's
        // about to attach the preview layer.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            let running = self.session.isRunning
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .info("configure() session.startRunning() returned, isRunning=\(running)")
            Task { @MainActor [weak self] in
                self?.debugInfo.startRunningSawIsRunning = running
            }
        }

        observeThermalAndBattery()

        // ─── PHASE 2: best-effort recipe application ───────────────
        // Off-main on the same queue so it runs after startRunning has
        // settled. Any failure logs loudly and leaves the device on
        // its default format — preview stays live regardless.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.applyRecipeBestEffort(on: videoDevice)
            }
        }

        log.info("configure() returning — preview should go live shortly")
        debugInfo.configureReturned = true
    }

    /// Best-effort recipe application. Picks the ideal recipe for the
    /// current SoC tier + thermal/battery state, asks DeviceCapabilities
    /// to step it down to a supported AVCaptureDevice.Format, and
    /// applies it. On any failure it logs the reason and leaves the
    /// device on its existing (default) format. The session is already
    /// running when we get here, so the preview never goes dark.
    private func applyRecipeBestEffort(on device: AVCaptureDevice) {
        socTier = DeviceCapabilities.currentTier()
        debugInfo.resolvedTier = socTier.rawValue
        let battery = UIDevice.current.batteryLevel
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let initialRecipe = DeviceCapabilities.liveRecipe(
            for: socTier,
            thermal: ProcessInfo.processInfo.thermalState,
            batteryLevel: battery,
            lowPower: lowPower)
        log.info("recipe: ideal=\(initialRecipe.resolution.rawValue)@\(initialRecipe.fps), tier=\(self.socTier.rawValue, privacy: .public)")

        let (resolvedFormat, resolvedRecipe) =
            DeviceCapabilities.resolveFormat(initialRecipe, on: device)
        guard let format = resolvedFormat else {
            log.warning("recipe: no AVCaptureDevice.Format satisfies any step-down — staying on device default")
            debugInfo.recipeOutcome = "NO FORMAT (fell back to device default)"
            return
        }
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try applyRecipe(resolvedRecipe,
                            format: format,
                            to: device,
                            scene: .outdoor)
            self.currentRecipe = resolvedRecipe
            // Re-pin codec / stabilization on the connection now that
            // the device may have switched format.
            if let connection = videoOutput.connection(with: .video) {
                let chosenCodec: AVVideoCodecType =
                    (resolvedRecipe.codec == .hevc
                     && videoOutput.availableVideoCodecTypes.contains(.hevc))
                    ? .hevc : .h264
                videoOutput.setOutputSettings(
                    [AVVideoCodecKey: chosenCodec], for: connection)
                connection.preferredVideoStabilizationMode =
                    stabilizationMode(for: resolvedRecipe.stabilization,
                                      on: connection)
            }
            log.info("recipe APPLIED: \(resolvedRecipe.resolution.rawValue)@\(resolvedRecipe.fps) \(resolvedRecipe.codec.rawValue, privacy: .public) stab=\(resolvedRecipe.stabilization.rawValue, privacy: .public)")
            debugInfo.recipeOutcome = "APPLIED \(resolvedRecipe.resolution.rawValue)@\(resolvedRecipe.fps) \(resolvedRecipe.codec.rawValue) \(resolvedRecipe.stabilization.rawValue)"
            Task.detached { [tier = socTier, recipe = resolvedRecipe] in
                await DiagnosticsStore.shared.recordEnum(
                    .captureSoCTier, value: tier)
                await DiagnosticsStore.shared.recordEnum(
                    .captureRecipeResolution, value: recipe.resolution)
            }
        } catch {
            log.error("recipe apply FAILED: \(error.localizedDescription) — staying on device default; preview unaffected")
            debugInfo.recipeOutcome = "FAILED: \(error.localizedDescription)"
        }
    }

    /// External watchdog hook: if the preview hasn't gone live within
    /// the UI's grace period, force-start the session again and log.
    /// Safe to call from any thread; no-ops if already running.
    func forceRestartIfStalled() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                Logger(subsystem: "com.playercut.app", category: "Capture")
                    .info("watchdog: session already running, no-op")
                Task { @MainActor [weak self] in
                    self?.debugInfo.watchdogSawIsRunning = true
                }
                return
            }
            Logger(subsystem: "com.playercut.app", category: "Capture")
                .error("watchdog: session NOT running after grace period — force-starting")
            Task { @MainActor [weak self] in
                self?.debugInfo.watchdogSawIsRunning = false
                self?.debugInfo.watchdogForcedRestart = true
            }
            self.session.startRunning()
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
        let sceneNow = currentSession?.sceneType ?? .outdoor
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try applyRecipe(resolvedRecipe,
                            format: format,
                            to: device,
                            scene: sceneNow)
            currentRecipe = resolvedRecipe
            // Update the in-flight session so the persisted recipe
            // reflects what we actually recorded with.
            if var live = currentSession {
                live.captureRecipe = resolvedRecipe
                currentSession = live
            }
            log.info("Capture downgrade (\(trigger == .thermal ? "thermal" : "battery", privacy: .public)): \(fromDesc, privacy: .public) → \(toDesc, privacy: .public)")
            Task.detached {
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
            log.error("Downgrade reconfigure failed: \(error.localizedDescription)")
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

    /// One-shot pre-flight: starts the session if needed, taps a single
    /// video frame, returns `.indoor` if mean Y-plane luminance is
    /// below 0.3 (gym/practice room), `.outdoor` otherwise. Times out at
    /// 2 s with `.outdoor` so a misbehaving device never blocks
    /// recording start.
    private func sampleSceneType() async -> SceneType {
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        let delegate = SceneLuminanceDelegate()
        let queue = DispatchQueue(label: "playercut.scene.detect")
        dataOutput.setSampleBufferDelegate(delegate, queue: queue)

        session.beginConfiguration()
        guard session.canAddOutput(dataOutput) else {
            session.commitConfiguration()
            log.warning("Scene detect: cannot add data output, defaulting outdoor")
            return .outdoor
        }
        session.addOutput(dataOutput)
        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }

        let luminance = await delegate.firstLuminance(timeoutSeconds: 2.0)

        session.beginConfiguration()
        session.removeOutput(dataOutput)
        session.commitConfiguration()

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
        if let device = videoDevice, let recipe = currentRecipe {
            try? applyRecipe(recipe,
                             format: device.activeFormat,
                             to: device,
                             scene: scene)
        }

        if !session.isRunning {
            session.startRunning()
        }
        videoOutput.startRecording(to: videoURL, recordingDelegate: self)

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
        videoOutput.stopRecording()
        // The delegate writes the file; we wait briefly for finalization.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Write loudness sidecar
        let payload = try JSONEncoder().encode(loudnessSamples)
        try payload.write(to: game.audioLoudnessURL, options: .atomic)

        game.endedAt = Date()
        game.status = .awaitingProcessing
        currentSession = nil

        if session.isRunning {
            session.stopRunning()
        }
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
