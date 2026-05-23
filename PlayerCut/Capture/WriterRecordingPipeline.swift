//
//  WriterRecordingPipeline.swift
//  PlayerCut/Capture
//
//  EXPERIMENTAL stock-Camera-grade recording path. Replaces
//  AVCaptureMovieFileOutput with AVCaptureVideoDataOutput +
//  AVCaptureAudioDataOutput + AVAssetWriter so we get
//    1. Explicit bitrate control (~45 Mbps for 4K HEVC, ~25 Mbps
//       for 1080p HEVC) — matches the stock Camera app's rates.
//    2. P3 color metadata preserved on the file (writer input's
//       sourceFormatHint inherits the CMFormatDescription from the
//       first sample buffer, which carries the device.activeColorSpace
//       tag set in applyRecipeOnSessionQueue).
//    3. No "AVCaptureMovieFileOutput defaults" surface — the writer's
//       compressionProperties are the single source of truth.
//
//  Gated by UserDefaults flag "playercut.experimental.writerCapture"
//  — default OFF. The legacy AVCaptureMovieFileOutput path remains
//  the production default until on-device side-by-side verification
//  confirms this writer pipeline matches stock-Camera quality without
//  regression.
//
//  // SOURCE: objc.io issues/23-video (accessed 2026-05-22) — the
//  //          canonical "stock-quality" recipe.
//  // SOURCE: Apple AVAssetWriter docs; AVAssetWriterInput
//  //          compressionProperties (AVVideoAverageBitRateKey,
//  //          AVVideoProfileLevelKey).
//

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import os.log

/// Owns the live writer session for one recording. Construct, hand to
/// the capture controller as the delegate for the video + audio data
/// outputs, and call `finish(...)` on stop. Not reusable — make a
/// fresh instance per recording.
final class WriterRecordingPipeline: NSObject {

    /// Tunables surfaced so the controller can pin them off the
    /// recipe at construct time.
    struct Settings {
        /// Video output dimensions (typically the active format's
        /// dimensions; for a 1080p recipe this is 1920x1080, for
        /// 4K it's 3840x2160).
        var videoSize: CGSize
        /// HEVC AverageBitRate. ~45 Mbps for 4K, ~25 Mbps for 1080p
        /// per the spec.
        var videoBitRate: Int
        /// Audio bit rate (~256 kbps) and sample rate (48 kHz).
        var audioBitRate: Int = 256_000
        var audioSampleRate: Double = 48_000
        var audioChannelCount: Int = 2
    }

    enum Status: Equatable {
        case idle
        case writing
        case finalizing
        case finished
        case failed(Error)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.writing, .writing),
                 (.finalizing, .finalizing),
                 (.finished, .finished):
                return true
            case (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "Writer")
    private let writerQueue = DispatchQueue(
        label: "com.playercut.writer.queue")

    private(set) var status: Status = .idle
    let outputURL: URL
    private let settings: Settings

    /// AVAssetWriter and its two inputs. Created lazily on first
    /// video sample so we can pin sourceFormatHint to the actual
    /// CMFormatDescription Apple hands us (this is how the file
    /// inherits the device.activeColorSpace = .P3_D65 tag).
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var firstVideoPTS: CMTime?
    private var droppedAudioBeforeVideo = 0

    init(outputURL: URL, settings: Settings) {
        self.outputURL = outputURL
        self.settings = settings
        super.init()
    }

    // MARK: - Public API (called from sessionQueue / capture controller)

    /// Stops accepting samples and finalizes the file. Completion is
    /// called on the writer queue once the file is on disk; if the
    /// writer hit an error mid-recording the completion sees `.failed`.
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        writerQueue.async { [self] in
            guard let writer else {
                // Never received a video frame → file would be empty.
                let err = NSError(domain: "WriterRecordingPipeline",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "recording captured no video frames"])
                status = .failed(err)
                completion(.failure(err))
                return
            }
            switch writer.status {
            case .writing:
                status = .finalizing
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if let err = writer.error {
                        log.error("finishWriting error: \(err.localizedDescription)")
                        status = .failed(err)
                        completion(.failure(err))
                    } else {
                        log.info("finishWriting OK: \(self.outputURL.lastPathComponent, privacy: .public)")
                        status = .finished
                        completion(.success(self.outputURL))
                    }
                }
            case .failed:
                let err = writer.error ?? NSError(
                    domain: "WriterRecordingPipeline", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "writer failed"])
                status = .failed(err)
                completion(.failure(err))
            default:
                let err = NSError(domain: "WriterRecordingPipeline",
                                  code: 3,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "writer in unexpected status \(writer.status.rawValue)"])
                completion(.failure(err))
            }
        }
    }

    // MARK: - Internal: lazy writer setup

    /// Builds the writer + inputs on first video sample. Pulling the
    /// CMFormatDescription off the sample buffer is the only way to
    /// keep color tags (P3 primaries, Rec.709 transfer) attached to
    /// the file — sourceFormatHint inherits everything we need.
    private func setupWriterIfNeeded(firstVideo sample: CMSampleBuffer) {
        guard writer == nil else { return }
        let videoFormat = CMSampleBufferGetFormatDescription(sample)
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let w = try AVAssetWriter(outputURL: outputURL,
                                      fileType: .mp4)
            // ── video input ──
            // Explicit compression properties pin the bitrate (the
            // whole point of switching off MovieFileOutput).
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(settings.videoSize.width),
                AVVideoHeightKey: Int(settings.videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.videoBitRate,
                    AVVideoProfileLevelKey:
                        kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            let vIn = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: videoSettings,
                sourceFormatHint: videoFormat)
            vIn.expectsMediaDataInRealTime = true
            if w.canAdd(vIn) {
                w.add(vIn)
            } else {
                log.error("writer cannot add video input")
            }

            // ── audio input ──
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.audioSampleRate,
                AVNumberOfChannelsKey: settings.audioChannelCount,
                AVEncoderBitRateKey: settings.audioBitRate
            ]
            let aIn = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) {
                w.add(aIn)
            } else {
                log.warning("writer cannot add audio input — recording will be silent")
            }

            self.writer = w
            self.videoInput = vIn
            self.audioInput = aIn
            log.info("writer constructed: \(Int(self.settings.videoSize.width))×\(Int(self.settings.videoSize.height)) HEVC @\(self.settings.videoBitRate / 1_000_000)Mbps; audio AAC \(self.settings.audioBitRate / 1000)kbps")
        } catch {
            log.error("writer init failed: \(error.localizedDescription)")
            status = .failed(error)
        }
    }

    /// Starts the writer session on the first video sample's PTS.
    /// Audio samples that arrived before this point are dropped (we
    /// only count them in the log so the user can see the timing
    /// gap on the diagnostic overlay).
    private func startSessionIfNeeded(_ pts: CMTime) {
        guard firstVideoPTS == nil, let writer else { return }
        if writer.startWriting() {
            writer.startSession(atSourceTime: pts)
            firstVideoPTS = pts
            status = .writing
            log.info("writer.startSession at PTS=\(CMTimeGetSeconds(pts), format: .fixed(precision: 3))s; dropped audio frames before start: \(self.droppedAudioBeforeVideo)")
        } else {
            log.error("writer.startWriting refused; status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
        }
    }

    // MARK: - Sample appending (called from session output queues)

    func appendVideoSample(_ sample: CMSampleBuffer) {
        writerQueue.async { [self] in
            guard status != .finished, status != .finalizing else { return }
            setupWriterIfNeeded(firstVideo: sample)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            startSessionIfNeeded(pts)
            guard let videoInput, videoInput.isReadyForMoreMediaData else {
                return
            }
            if !videoInput.append(sample) {
                if let err = writer?.error {
                    log.error("video append failed: \(err.localizedDescription)")
                    status = .failed(err)
                }
            }
        }
    }

    func appendAudioSample(_ sample: CMSampleBuffer) {
        writerQueue.async { [self] in
            guard status != .finished, status != .finalizing else { return }
            // Audio before video → no session yet → drop.
            guard firstVideoPTS != nil else {
                droppedAudioBeforeVideo += 1
                return
            }
            guard let audioInput, audioInput.isReadyForMoreMediaData else {
                return
            }
            if !audioInput.append(sample) {
                if let err = writer?.error {
                    log.error("audio append failed: \(err.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Sample-buffer delegate fan-out

/// Tiny shim so AVCaptureVideoDataOutput can drive the writer
/// directly without GameCaptureController acting as the delegate
/// (which would risk crossing the @MainActor isolation barrier on
/// every frame).
final class WriterVideoDelegate: NSObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    weak var pipeline: WriterRecordingPipeline?
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        pipeline?.appendVideoSample(sampleBuffer)
    }
}

/// Audio fan-out delegate. Appends to the writer AND lets the
/// existing GameCaptureController loudness path see the buffer.
final class WriterAudioDelegate: NSObject,
                                  AVCaptureAudioDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    weak var pipeline: WriterRecordingPipeline?
    /// Optional secondary delegate (the existing loudness extension
    /// on GameCaptureController). Forwarding lets the loudness
    /// sidecar continue to be written even in writer mode.
    weak var loudnessDelegate: AVCaptureAudioDataOutputSampleBufferDelegate?

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        pipeline?.appendAudioSample(sampleBuffer)
        // The protocol method is @objc optional — call only when the
        // forwarded delegate actually responds. The objc runtime
        // bridge handles this cleanly.
        if let secondary = loudnessDelegate {
            secondary.captureOutput?(output,
                                     didOutput: sampleBuffer,
                                     from: connection)
        }
    }
}

// MARK: - Feature flag

/// Reads the experimental-writer-capture flag from UserDefaults.
/// Default OFF. Production stays on the legacy AVCaptureMovieFileOutput
/// path until on-device side-by-side verification.
enum WriterCaptureFlag {
    static let defaultsKey = "playercut.experimental.writerCapture"
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
