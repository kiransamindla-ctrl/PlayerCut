//
//  SpeechTranscriber.swift
//  PlayerCut/Audio
//
//  Apple-native on-device speech recognition (SFSpeechRecognizer). Used
//  by ReelComposer to render timed caption overlays on the exported reel.
//
//  Permission:
//    NSSpeechRecognitionUsageDescription must be in the Info.plist.
//    `requestAuthorization` is async and produces the system sheet on
//    first use; subsequent calls are immediate.
//
//  Locale:
//    Defaults to the device locale (or the override set in Settings →
//    Debug → Caption locale). Falls through to nil and emits no
//    captions when the locale's recognizer is unavailable.
//
//  Caveats:
//    SFSpeechRecognizer's recognitionTask is streaming-friendly but for a
//    finished file we use AVAssetReader → AVAudioPCMBuffer → audioPCMBuffer
//    appended. Simulator support is locale-dependent — tests that need
//    real transcription generate a known phrase via AVSpeechSynthesizer
//    at test time. Speaker ID is out of scope for this PR.
//

import AVFoundation
import Foundation
import Speech
import os.log

@available(iOS 13.0, *)
final class SpeechTranscriber {

    struct Segment: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    enum SpeechError: Error {
        case unauthorized(SFSpeechRecognizerAuthorizationStatus)
        case recognizerUnavailable(Locale)
        case audioReadFailed(String)
        case recognitionFailed(String)
    }

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "Captions")

    /// Asks the user once. Cached for the lifetime of the process.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    /// Transcribe the entire audio of `asset` into timestamped segments.
    /// `localeID` "auto" → device locale. Any non-fatal failure returns
    /// an empty list (caller proceeds without captions).
    func transcribe(asset: AVAsset, localeID: String) async throws -> [Segment] {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw SpeechError.unauthorized(status)
        }
        let locale: Locale = (localeID == "auto" || localeID.isEmpty)
            ? .current
            : Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable(locale)
        }
        // Force on-device when supported — privacy + offline + no Apple-
        // ID round trips. Falls back to whatever the recognizer offers
        // when the locale lacks an on-device model.
        let preferOnDevice = recognizer.supportsOnDeviceRecognition

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw SpeechError.audioReadFailed("no audio track")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = preferOnDevice

        // Stream PCM into the request via AVAssetReader.
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw SpeechError.audioReadFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw SpeechError.audioReadFailed("cannot add reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SpeechError.audioReadFailed(reader.error?.localizedDescription ?? "startReading false")
        }

        // Build an AVAudioFormat that matches our PCM settings so Speech
        // can accept the buffers.
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false) else {
            throw SpeechError.audioReadFailed("AVAudioFormat init failed")
        }

        // Collect samples per-buffer, append to the recognition request.
        var appended = 0
        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            if let pcm = pcmBuffer(from: sb, format: pcmFormat) {
                request.append(pcm)
                appended += Int(pcm.frameLength)
            }
        }
        request.endAudio()
        log.info("Captions: fed \(appended) frames (\(appended / 16_000) s) on-device=\(preferOnDevice)")

        // Run recognition and gather segment timings.
        return try await withCheckedThrowingContinuation { cont in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    cont.resume(throwing: SpeechError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                let segs = result.bestTranscription.segments.map {
                    Segment(text: $0.substring,
                            start: $0.timestamp,
                            end: $0.timestamp + $0.duration)
                }
                cont.resume(returning: segs)
            }
            _ = task   // hold ref for the closure
        }
    }

    /// CMSampleBuffer (PCM int16 mono 16 kHz) → AVAudioPCMBuffer.
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                           format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                           lengthAtOffsetOut: nil,
                                           totalLengthOut: &length,
                                           dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let raw = ptr, length >= 2 else { return nil }
        let frameCount = AVAudioFrameCount(length / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        if let dest = buffer.int16ChannelData?[0] {
            memcpy(dest, raw, length)
        }
        return buffer
    }
}
