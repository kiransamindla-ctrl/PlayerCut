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

    func configure() throws {
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
        } catch {
            log.warning("AVAudioSession config failed: \(error.localizedDescription)")
        }

        // Battery monitoring has to be opted into before UIDevice will
        // report a real level. Cheap to enable; survives backgrounding.
        UIDevice.current.isBatteryMonitoringEnabled = true

        session.beginConfiguration()
        // sessionPreset MUST be .inputPriority when we set
        // device.activeFormat ourselves — otherwise the preset
        // overrides the format we just picked. The recipe-based path
        // owns resolution/fps from here on.
        session.sessionPreset = .inputPriority

        // Video input — prefer the ultrawide on A12+ phones because it
        // captures more of the sideline at the same tripod distance.
        // Fall back to the standard wide if the device doesn't expose
        // an ultrawide (older models, or specific iPhone SEs).
        let videoDevice: AVCaptureDevice
        if let ultrawide = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                   for: .video,
                                                   position: .back) {
            videoDevice = ultrawide
            log.info("Capture device: builtInUltraWideCamera")
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .back) {
            videoDevice = wide
            log.info("Capture device: builtInWideAngleCamera (no ultrawide available)")
        } else {
            throw PipelineError.captureFailed("No back camera available")
        }

        // ----- Adaptive capture recipe -----
        // Pick a recipe from the SoC tier + live thermal/battery state,
        // then resolve it to a concrete activeFormat on this device.
        // Step-downs (no HEVC at the requested rate → drop fps; no
        // 4K → drop to 1080p) all happen inside resolveFormat.
        socTier = DeviceCapabilities.currentTier()
        let battery = UIDevice.current.batteryLevel
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let initialRecipe = DeviceCapabilities.liveRecipe(
            for: socTier,
            thermal: ProcessInfo.processInfo.thermalState,
            batteryLevel: battery,
            lowPower: lowPower)
        let (resolvedFormat, resolvedRecipe) =
            DeviceCapabilities.resolveFormat(initialRecipe, on: videoDevice)
        guard let format = resolvedFormat else {
            throw PipelineError.captureFailed(
                "No AVCaptureDevice.Format satisfies any recipe step-down")
        }
        try applyRecipe(resolvedRecipe,
                        format: format,
                        to: videoDevice,
                        scene: .outdoor)
        self.currentRecipe = resolvedRecipe
        self.videoDevice = videoDevice
        log.info("Recipe: tier=\(self.socTier.rawValue) → \(resolvedRecipe.resolution.rawValue)@\(resolvedRecipe.fps) \(resolvedRecipe.codec.rawValue, privacy: .public) stab=\(resolvedRecipe.stabilization.rawValue, privacy: .public)")
        Task.detached { [tier = socTier, recipe = resolvedRecipe] in
            await DiagnosticsStore.shared.recordEnum(.captureSoCTier, value: tier)
            await DiagnosticsStore.shared.recordEnum(
                .captureRecipeResolution, value: recipe.resolution)
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw PipelineError.captureFailed("Cannot add video input")
        }
        session.addInput(videoInput)

        // Audio input
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw PipelineError.captureFailed("No audio device")
        }
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            throw PipelineError.captureFailed("Cannot add audio input")
        }
        session.addInput(audioInput)

        // Movie file output. The codec selection is gated by the
        // recipe — when we resolved to .h264 (HEVC unavailable on this
        // format) we honor that explicitly.
        guard session.canAddOutput(videoOutput) else {
            throw PipelineError.captureFailed("Cannot add movie file output")
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            let chosenCodec: AVVideoCodecType
            if resolvedRecipe.codec == .hevc,
               videoOutput.availableVideoCodecTypes.contains(.hevc) {
                chosenCodec = .hevc
            } else {
                chosenCodec = .h264
            }
            videoOutput.setOutputSettings(
                [AVVideoCodecKey: chosenCodec], for: connection)
            connection.preferredVideoStabilizationMode =
                stabilizationMode(for: resolvedRecipe.stabilization,
                                  on: connection)
        }

        // Audio data tap for loudness
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioDataOutput) else {
            throw PipelineError.captureFailed("Cannot add audio data output")
        }
        session.addOutput(audioDataOutput)

        session.commitConfiguration()
        log.info("Capture session configured")

        observeThermalAndBattery()
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
