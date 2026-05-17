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

    // MARK: - Entry point

    func detect(in game: GameSession) async throws -> Stage1Result {
        let startedAt = Date()

        async let audio = detectAudioPeaks(loudnessURL: game.audioLoudnessURL)
        async let motion = detectMotionPeaks(videoURL: game.rawVideoURL)

        let audioWindows = try await audio
        let motionWindows = try await motion
        log.info("Stage 1: \(audioWindows.count) audio + \(motionWindows.count) motion windows")

        let merged = mergeAndDedupe(audio: audioWindows, motion: motionWindows)
        let trimmed = Array(merged.prefix(maxCandidates))

        if trimmed.count < 12 {
            throw PipelineError.insufficientCandidates(found: trimmed.count, needed: 12)
        }

        return Stage1Result(candidates: trimmed,
                            processingDuration: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Audio

    private func detectAudioPeaks(loudnessURL: URL) async throws -> [CandidateWindow] {
        let data = try Data(contentsOf: loudnessURL)
        let samples = try JSONDecoder().decode([GameCaptureController.LoudnessSample].self,
                                               from: data)
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
            if s.rms > mean + audioSigmaThreshold * stdev {
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

    private func detectMotionPeaks(videoURL: URL) async throws -> [CandidateWindow] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let frameInterval = 1.0 / flowProxyFPS

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var times: [CMTime] = []
        var t = 0.0
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += frameInterval
        }

        var previousPixelBuffer: CVPixelBuffer?
        var magnitudes: [(time: Double, mag: Float)] = []

        for time in times {
            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                continue
            }
            let pixelBuffer = try makePixelBuffer(from: cgImage)

            if let prev = previousPixelBuffer {
                let mag = try await opticalFlowMagnitude(from: prev, to: pixelBuffer)
                magnitudes.append((time.seconds, mag))
            }
            previousPixelBuffer = pixelBuffer
        }
        log.info("Stage 1 flow: \(magnitudes.count) frames analyzed")

        return findFlowPeaks(magnitudes)
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

    private func findFlowPeaks(_ magnitudes: [(time: Double, mag: Float)])
        -> [CandidateWindow] {
        guard magnitudes.count > 10 else { return [] }

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
            if entry.mag > mean + flowSigmaThreshold * stdev {
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

    // MARK: - Helpers

    private func makePixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw PipelineError.stage1Failed("Pixel buffer alloc")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
