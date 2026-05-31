//
//  AudioPeakDetector.swift
//  PlayerCut/Composition
//
//  Per-clip audio peak detection driven directly from the source clip
//  (no pre-written loudness sidecar). Native AVFoundation: AVAssetReader
//  decodes the clip's source-time window to 16 kHz mono PCM, we walk
//  RMS over 50 ms hops, and return the offset (in source-time, relative
//  to the clip start) where the loudest hop landed.
//
//  Used by ReelComposer to time the duck-the-music / boost-the-game-audio
//  ramps to the actual "hit" in each clip — the cheer, whistle, contact —
//  instead of guessing from the ranker's energy score.
//

import AVFoundation
import Foundation
import os.log

enum AudioPeakDetector {

    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "AudioPeak")
    private static let sampleRate: Double = 16_000
    private static let hopSeconds: Double = 0.05  // ~20 RMS windows / second

    /// Returns the source-time offset within `[sourceStart, sourceEnd]` of
    /// the loudest audio hop, or nil when the clip has no audio / the read
    /// fails. The returned offset is measured from `sourceStart` so callers
    /// don't need to subtract.
    static func detectPeakOffset(in audioTrack: AVAssetTrack,
                                 sourceStart: Double,
                                 sourceEnd: Double) async -> Double? {
        guard sourceEnd > sourceStart, let asset = audioTrack.asset else { return nil }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            log.warning("peak: AVAssetReader init failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: sourceStart, preferredTimescale: 600),
            duration: CMTime(seconds: sourceEnd - sourceStart, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            log.warning("peak: startReading failed (\(reader.error?.localizedDescription ?? "nil", privacy: .public))")
            return nil
        }

        let hopFrames = max(1, Int(hopSeconds * sampleRate))
        var bestRMS: Double = -1
        var bestOffsetSamples: Int64 = 0
        var elapsedSamples: Int64 = 0

        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let raw = ptr, length >= 2 else { continue }
            let nSamples = length / 2
            // Copy the s16 frames into a stable buffer so we can iterate in
            // hops without worrying about block-buffer lifetime semantics.
            let samples = raw.withMemoryRebound(to: Int16.self, capacity: nSamples) { p in
                Array(UnsafeBufferPointer(start: p, count: nSamples))
            }

            var i = 0
            while i + hopFrames <= samples.count {
                var sumSq: Double = 0
                for j in i..<(i + hopFrames) {
                    let v = Double(samples[j])
                    sumSq += v * v
                }
                let rms = (sumSq / Double(hopFrames)).squareRoot()
                if rms > bestRMS {
                    bestRMS = rms
                    bestOffsetSamples = elapsedSamples + Int64(i)
                }
                i += hopFrames
            }
            elapsedSamples += Int64(samples.count)
        }
        if reader.status == .failed {
            log.warning("peak: reader failed (\(reader.error?.localizedDescription ?? "nil", privacy: .public))")
        }
        guard bestRMS > 0 else { return nil }
        return Double(bestOffsetSamples) / sampleRate
    }
}
