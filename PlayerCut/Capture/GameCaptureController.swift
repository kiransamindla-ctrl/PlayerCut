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

    struct LoudnessSample: Codable {
        let t: Double      // seconds since recording start
        let rms: Float     // 0..1
    }

    // MARK: - Setup

    func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // Video input — back wide camera
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: .back) else {
            throw PipelineError.captureFailed("No back camera")
        }
        try lockCameraForGame(videoDevice, scene: .outdoor)
        self.videoDevice = videoDevice
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

        // Movie file output (HEVC 1080p30)
        guard session.canAddOutput(videoOutput) else {
            throw PipelineError.captureFailed("Cannot add movie file output")
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            if videoOutput.availableVideoCodecTypes.contains(.hevc) {
                videoOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc],
                                              for: connection)
            }
            connection.preferredVideoStabilizationMode = .standard
        }

        // Audio data tap for loudness
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioDataOutput) else {
            throw PipelineError.captureFailed("Cannot add audio data output")
        }
        session.addOutput(audioDataOutput)

        session.commitConfiguration()
        log.info("Capture session configured")
    }

    /// Lock focus, exposure, and white balance at game start. Tripod is static —
    /// auto-anything causes pumping/flicker and burns battery.
    ///
    /// Scene-aware: indoor venues get a tight fluorescent-targeted WB
    /// lock (4000 K, neutral tint) which kills the green cast typical
    /// of school-gym lighting; outdoor venues lock at whatever WB the
    /// camera auto-detected, which copes well with daylight + cloud.
    private func lockCameraForGame(_ device: AVCaptureDevice,
                                   scene: SceneType) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
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
        // 30 fps, locked
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
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
        if let device = videoDevice {
            try? lockCameraForGame(device, scene: scene)
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
                               sceneType: scene)
        currentSession = game
        log.info("Recording started: \(id.uuidString) trigger=\(triggerSource.rawValue) scene=\(scene.rawValue)")
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
