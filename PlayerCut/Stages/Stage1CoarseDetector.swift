//
//  Stage1CoarseDetector.swift
//  PlayerCut
//
//  Stage 1: produces ~30–80 candidate windows from a 90-min game using only
//  cheap signals. NEVER runs heavy models on the full video.
//

import AVFoundation
import Vision
import Foundation
import os.log

actor Stage1CoarseDetector {

    private let log = Logger(subsystem: "com.playercut.app", category: "Stage1")

    // Tuning knobs — adjust empirically against labeled games
    private let audioBaselineWindow: Double = 5.0   // seconds
    private let audioSigmaThreshold: Float = 2.0
    private let audioMinPeakDuration: Double = 0.6  // seconds above threshold
    private let audioPrePeak: Double = 4.0
    private let audioPostPeak: Double = 4.0

    private let flowProxyFPS: Double = 2.0
    private let flowSigmaThreshold: Float = 2.0

    private let maxCandidates = 80

    // 320×180 BGRA pool: we copy each FrameIterator output into a pool slot
    // so the "previous" frame for optical flow stays valid even after the
    // reader's internal buffer is recycled.
    private let flowPool = PixelBufferPool(width: 320, height: 180)

    // MARK: - Memory pressure

    /// Releases pooled buffers. Called by the orchestrator on critical
    /// memory-pressure events.
    func flushPools() {
        flowPool.flush()
    }

    // MARK: - Entry point

    func detect(in game: GameSession) async throws -> Stage1Result {
        let startedAt = Date()
        log.info("Stage 1 detect: starting")

        // Duration-aware minimum: one candidate per 30 s of source, but
        // never less than 1. A 60-second solo-practice clip should still
        // produce something usable, even if there's only one "moment".
        let videoDurationSeconds = try await videoDuration(at: game.rawVideoURL)
        let minCandidates = max(1, Int(videoDurationSeconds / 30))
        log.info("Stage 1: duration=\(videoDurationSeconds, format: .fixed(precision: 1))s → minCandidates=\(minCandidates)")

        var (audioWindows, motionWindows) = try await runDetectors(
            loudnessURL: game.audioLoudnessURL,
            videoURL: game.rawVideoURL,
            audioSigma: audioSigmaThreshold,
            flowSigma: flowSigmaThreshold)

        var merged = mergeAndDedupe(audio: audioWindows, motion: motionWindows)
        var trimmed = Array(merged.prefix(maxCandidates))

        // Soft fallback: if first pass didn't clear the duration-aware
        // floor, lower σ by 0.5 and try once more. Catches quiet/low-
        // motion clips (solo practice, indoor drills) without losing the
        // production thresholds in normal use.
        if trimmed.count < minCandidates {
            log.info("Stage 1 fallback: \(trimmed.count) < \(minCandidates), retrying with σ-0.5")
            let (a2, m2) = try await runDetectors(
                loudnessURL: game.audioLoudnessURL,
                videoURL: game.rawVideoURL,
                audioSigma: max(0.5, audioSigmaThreshold - 0.5),
                flowSigma: max(0.5, flowSigmaThreshold - 0.5))
            audioWindows = a2
            motionWindows = m2
            merged = mergeAndDedupe(audio: a2, motion: m2)
            trimmed = Array(merged.prefix(maxCandidates))
            log.info("Stage 1 fallback: produced \(trimmed.count) candidates")
        }

        // Only truly empty videos fail. Anything ≥1 candidate is honored;
        // downstream (HighlightRanker) handles short clip lists gracefully.
        if trimmed.isEmpty {
            log.warning("Stage 1: no candidates after retry — video appears empty")
            throw PipelineError.insufficientCandidates(found: 0, needed: 1)
        }

        log.info("Stage 1 done: \(trimmed.count) candidates (audio=\(audioWindows.count), motion=\(motionWindows.count))")
        return Stage1Result(candidates: trimmed,
                            processingDuration: Date().timeIntervalSince(startedAt))
    }

    private func videoDuration(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    private func runDetectors(loudnessURL: URL,
                              videoURL: URL,
                              audioSigma: Float,
                              flowSigma: Float) async throws
        -> ([CandidateWindow], [CandidateWindow]) {
        async let audio = detectAudioPeaks(loudnessURL: loudnessURL,
                                           sigma: audioSigma)
        async let motion = detectMotionPeaks(videoURL: videoURL,
                                             sigma: flowSigma)
        let a = try await audio
        let m = try await motion
        return (a, m)
    }

    // MARK: - Audio

    private func detectAudioPeaks(loudnessURL: URL,
                                  sigma: Float) async throws -> [CandidateWindow] {
        log.info("Stage 1 audio: reading loudness file")
        let data = try Data(contentsOf: loudnessURL)
        let samples = try JSONDecoder().decode([GameCaptureController.LoudnessSample].self,
                                               from: data)
        log.info("Stage 1 audio: \(samples.count) loudness samples")
        guard samples.count > 20 else { return [] }

        let sampleRateHz = Double(samples.count) /
            max(1.0, samples.last!.t - samples.first!.t)
        let baselineSamples = max(5, Int(audioBaselineWindow * sampleRateHz))

        var aboveThreshold: [(time: Double, rms: Float)] = []

        // Rolling baseline: mean and stdev of trailing window
        var window: [Float] = []
        for s in samples {
            window.append(s.rms)
            if window.count > baselineSamples {
                window.removeFirst()
            }
            guard window.count >= baselineSamples else { continue }
            let mean = window.reduce(0, +) / Float(window.count)
            let variance = window.map { ($0 - mean) * ($0 - mean) }
                .reduce(0, +) / Float(window.count)
            let stdev = sqrt(variance)
            if s.rms > mean + sigma * stdev {
                aboveThreshold.append((s.t, s.rms))
            }
        }

        // Cluster contiguous above-threshold samples into peaks
        var peaks: [Double] = []
        var clusterStart: Double? = nil
        var clusterPeakTime: Double = 0
        var clusterPeakValue: Float = 0
        var lastT: Double = -1

        let gap = 1.0 / sampleRateHz * 1.5

        for entry in aboveThreshold {
            if let _ = clusterStart, entry.time - lastT > gap {
                // Close out previous cluster
                peaks.append(clusterPeakTime)
                clusterStart = nil
                clusterPeakValue = 0
            }
            if clusterStart == nil { clusterStart = entry.time }
            if entry.rms > clusterPeakValue {
                clusterPeakValue = entry.rms
                clusterPeakTime = entry.time
            }
            lastT = entry.time
        }
        if clusterStart != nil { peaks.append(clusterPeakTime) }

        // Convert peaks to windows
        return peaks.map { peak in
            CandidateWindow(id: UUID(),
                            startTime: max(0, peak - audioPrePeak),
                            endTime: peak + audioPostPeak,
                            audioScore: 1.0,
                            motionScore: 0.0)
        }
    }

    // MARK: - Optical flow on a 320x180 proxy

    private func detectMotionPeaks(videoURL: URL,
                                   sigma: Float) async throws -> [CandidateWindow] {
        log.info("Stage 1 motion: loading asset")
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        log.info("Stage 1 motion: duration=\(duration, format: .fixed(precision: 1))s, starting decode")

        let iterator = FrameIterator(url: videoURL)
        try await iterator.seek(to: 0,
                                endTime: duration,
                                outputSize: CGSize(width: 320, height: 180))

        let frameInterval = 1.0 / flowProxyFPS
        var lastEmittedTime: Double = -.infinity
        var previousPixelBuffer: CVPixelBuffer?
        var magnitudes: [(time: Double, mag: Float)] = []
        var decoded = 0
        let progressEvery = 60   // log roughly every 2s of source video at 30fps

        while let frame = await iterator.next() {
            decoded += 1
            if decoded % progressEvery == 0 {
                log.info("Stage 1 motion: decoded=\(decoded), flow pairs=\(magnitudes.count), at t=\(frame.time, format: .fixed(precision: 1))s")
            }
            if frame.time - lastEmittedTime < frameInterval { continue }
            lastEmittedTime = frame.time

            // Copy into a pooled 320x180 slot. The reader's buffer is
            // owned by AVAssetReader and may be recycled the moment we
            // call next() again; the pool gives us a stable buffer we can
            // hand to the next iteration as "previous".
            let current = copyToPool(frame.buffer) ?? frame.buffer

            if let prev = previousPixelBuffer {
                let mag = try await opticalFlowMagnitude(from: prev, to: current)
                magnitudes.append((frame.time, mag))
            }
            previousPixelBuffer = current
        }
        await iterator.cancel()
        log.info("Stage 1 flow: \(magnitudes.count) frames analyzed (decoded \(decoded) total)")

        return findFlowPeaks(magnitudes, sigma: sigma)
    }

    private func copyToPool(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let dest = flowPool.acquire() else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(dest)
        let height = CVPixelBufferGetHeight(source)
        let copyRow = min(srcRow, dstRow)
        for y in 0..<height {
            memcpy(dst.advanced(by: y * dstRow),
                   src.advanced(by: y * srcRow),
                   copyRow)
        }
        return dest
    }

    private func opticalFlowMagnitude(from prev: CVPixelBuffer,
                                      to next: CVPixelBuffer) async throws -> Float {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: next)
        request.computationAccuracy = .low
        let handler = VNImageRequestHandler(cvPixelBuffer: prev)
        try handler.perform([request])

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return 0
        }
        return Float(meanMagnitude(of: observation.pixelBuffer))
    }

    private func meanMagnitude(of flowBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(flowBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flowBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(flowBuffer)
        let height = CVPixelBufferGetHeight(flowBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(flowBuffer)
        guard let base = CVPixelBufferGetBaseAddress(flowBuffer) else { return 0 }

        // Format is 2-channel float (dx, dy)
        var sum: Double = 0
        var count: Int = 0
        for y in stride(from: 0, to: height, by: 4) {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: Float.self)
            for x in stride(from: 0, to: width, by: 4) {
                let dx = row[x * 2]
                let dy = row[x * 2 + 1]
                sum += Double(sqrtf(dx * dx + dy * dy))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private func findFlowPeaks(_ magnitudes: [(time: Double, mag: Float)],
                               sigma: Float) -> [CandidateWindow] {
        // For very short clips (≤10 samples = ≤5 s at 2 fps), fall back
        // to a single peak at the highest-magnitude frame so we don't
        // return empty when the user does a quick test recording.
        guard magnitudes.count > 10 else {
            if let best = magnitudes.max(by: { $0.mag < $1.mag }) {
                log.info("Stage 1 flow: short-clip fallback, single peak at t=\(best.time, format: .fixed(precision: 1))s")
                return [CandidateWindow(id: UUID(),
                                        startTime: max(0, best.time - 4),
                                        endTime: best.time + 4,
                                        audioScore: 0.0,
                                        motionScore: 1.0)]
            }
            return []
        }

        // Rolling baseline (10s window at 2fps = 20 samples)
        let windowSize = 20
        var peaks: [Double] = []
        var window: [Float] = []
        for entry in magnitudes {
            window.append(entry.mag)
            if window.count > windowSize { window.removeFirst() }
            guard window.count >= windowSize else { continue }
            let mean = window.reduce(0, +) / Float(window.count)
            let variance = window.map { ($0 - mean) * ($0 - mean) }
                .reduce(0, +) / Float(window.count)
            let stdev = sqrt(variance)
            if entry.mag > mean + sigma * stdev {
                peaks.append(entry.time)
            }
        }

        // Coalesce nearby peaks (within 6s)
        var coalesced: [Double] = []
        for p in peaks {
            if let last = coalesced.last, p - last < 6.0 { continue }
            coalesced.append(p)
        }

        return coalesced.map { peak in
            CandidateWindow(id: UUID(),
                            startTime: max(0, peak - 4),
                            endTime: peak + 4,
                            audioScore: 0.0,
                            motionScore: 1.0)
        }
    }

    // MARK: - Merge

    private func mergeAndDedupe(audio: [CandidateWindow],
                                motion: [CandidateWindow]) -> [CandidateWindow] {
        let all = (audio + motion).sorted { $0.startTime < $1.startTime }
        var merged: [CandidateWindow] = []

        for window in all {
            if var last = merged.last, window.startTime < last.endTime + 1.0 {
                // Overlap or near-adjacent → merge, take max scores
                last.endTime = max(last.endTime, window.endTime)
                last.audioScore = max(last.audioScore, window.audioScore)
                last.motionScore = max(last.motionScore, window.motionScore)
                merged[merged.count - 1] = last
            } else {
                merged.append(window)
            }
        }
        return merged
    }

}
