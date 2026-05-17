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

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let audioQueue = DispatchQueue(label: "playercut.audio.loudness")
    private var loudnessSamples: [LoudnessSample] = []
    private var loudnessSampleCounter = 0

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
        try lockCameraForGame(videoDevice)
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
    private func lockCameraForGame(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        // 30 fps, locked
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    }

    // MARK: - Lifecycle

    func startRecording(for player: PlayerEnrollment, sport: Sport) throws -> GameSession {
        let id = UUID()
        let dir = StoragePaths.gameDirectory(for: id)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let videoURL = dir.appendingPathComponent("raw.mov")
        let audioURL = dir.appendingPathComponent("audio_loudness.json")

        loudnessSamples.removeAll(keepingCapacity: true)
        loudnessSampleCounter = 0

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
                               exportedReelURL: nil,
                               status: .recording)
        currentSession = game
        log.info("Recording started: \(id.uuidString)")
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
