//
//  ColorMatchAnalyzer.swift
//  PlayerCut/Composition
//
//  PR #11 S3 — per-clip auto color match. Phone footage walks the
//  white balance: same field, same kid, every cut looks like a
//  different lens because the auto-WB shifts when the camera pans
//  through sun and shade. A creative LUT layered on top doesn't fix
//  that; only per-clip normalization does.
//
//  Strategy: sample each clip's mid-frame; compute mean RGB via
//  vDSP (same Accelerate path BPMDetector + AudioPeakDetector use);
//  compute a reel-wide median across all clips; emit a per-channel
//  multiplicative gain that nudges each clip's mean toward the
//  median. The correction is CAPPED (max ±18 % per channel) so a
//  genuinely dark clip isn't blown out.
//
//  The gain is applied inside MetalPetalCompositor BEFORE the LUT
//  blend so the creative grade still has the last word visually.
//

import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import os.log

enum ColorMatchAnalyzer {

    private static let logger = Logger(subsystem: "com.playercut.app",
                                       category: "ColorMatch")

    /// Per-channel multiplicative gain. r/g/b in [0.5, 2.0] range; 1.0
    /// means "no correction" — the identity that downstream code uses
    /// as a sentinel for "skip the pre-LUT pass entirely".
    struct ClipGain: Equatable {
        var r: Float
        var g: Float
        var b: Float

        static let identity = ClipGain(r: 1, g: 1, b: 1)

        /// True when the gain meaningfully diverges from identity.
        /// 1% tolerance — anything smaller is below visual perception.
        var isIdentity: Bool {
            abs(r - 1) < 0.01 && abs(g - 1) < 0.01 && abs(b - 1) < 0.01
        }
    }

    /// Empirical correction ceiling — 18 % nudge per channel. Beyond
    /// this we'd turn a genuinely under-exposed sun-into-lens clip into
    /// something that reads as "raised the gain too far". 18 % is enough
    /// to smooth a sun↔shade cut without overshooting; less than the
    /// 25 % a one-step exposure compensation would produce.
    static let maxChannelCorrection: Float = 0.18

    // MARK: - Per-clip mean sampling

    /// Samples one frame at `midTime` (or wherever clip's mid is),
    /// returns the unweighted mean RGB across all pixels. Uses vDSP
    /// for the per-channel mean — same pattern AudioPeakDetector
    /// applies on Int16 audio frames.
    static func meanRGB(at midTime: Double,
                        from asset: AVAsset,
                        downsampleLongEdge: Int = 256) async -> SIMD3<Float>? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25,
                                                  preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25,
                                                 preferredTimescale: 600)
        gen.maximumSize = CGSize(width: downsampleLongEdge,
                                 height: downsampleLongEdge)
        let t = CMTime(seconds: midTime, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else {
            return nil
        }
        return meanRGB(from: cg)
    }

    /// Pure helper — exposed for tests. Decode an arbitrary CGImage
    /// into RGBA bytes via CGContext, then average each channel via
    /// vDSP_meanv.
    static func meanRGB(from cgImage: CGImage) -> SIMD3<Float>? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes,
                            width: w, height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: rowBytes,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let pixelCount = w * h
        // Split-deinterleave into three Float vectors so vDSP can
        // take the mean per channel without a per-pixel branch.
        var rChan = [Float](repeating: 0, count: pixelCount)
        var gChan = [Float](repeating: 0, count: pixelCount)
        var bChan = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            rChan[i] = Float(bytes[i * 4 + 0])
            gChan[i] = Float(bytes[i * 4 + 1])
            bChan[i] = Float(bytes[i * 4 + 2])
        }
        var rMean: Float = 0
        var gMean: Float = 0
        var bMean: Float = 0
        rChan.withUnsafeBufferPointer { buf in
            vDSP_meanv(buf.baseAddress!, 1, &rMean, vDSP_Length(pixelCount))
        }
        gChan.withUnsafeBufferPointer { buf in
            vDSP_meanv(buf.baseAddress!, 1, &gMean, vDSP_Length(pixelCount))
        }
        bChan.withUnsafeBufferPointer { buf in
            vDSP_meanv(buf.baseAddress!, 1, &bMean, vDSP_Length(pixelCount))
        }
        // Normalize to [0,1] for the downstream median computation.
        return SIMD3<Float>(rMean / 255, gMean / 255, bMean / 255)
    }

    // MARK: - Reel-wide median + per-clip gain

    /// Pure helper. Given each clip's mean RGB, compute the median per
    /// channel and emit per-clip gains that nudge each clip toward the
    /// median, capped at ±`maxChannelCorrection`.
    static func gains(forMeans clipMeans: [SIMD3<Float>]) -> [ClipGain] {
        guard !clipMeans.isEmpty else { return [] }
        let rs = clipMeans.map { $0.x }.sorted()
        let gs = clipMeans.map { $0.y }.sorted()
        let bs = clipMeans.map { $0.z }.sorted()
        let medR = median(sortedValues: rs)
        let medG = median(sortedValues: gs)
        let medB = median(sortedValues: bs)
        return clipMeans.map { mean in
            ClipGain(
                r: cappedGain(target: medR, source: mean.x),
                g: cappedGain(target: medG, source: mean.y),
                b: cappedGain(target: medB, source: mean.z))
        }
    }

    /// Multiplicative gain that takes `source` toward `target` (gain ×
    /// source = target). Floors source at 0.03 so a near-black clip
    /// doesn't blow the gain past the cap; clamps the result so any
    /// single channel moves at most `maxChannelCorrection` from 1.0.
    static func cappedGain(target: Float, source: Float) -> Float {
        let safeSource = max(0.03, source)
        let raw = target / safeSource
        let lo = 1 - maxChannelCorrection
        let hi = 1 + maxChannelCorrection
        return min(hi, max(lo, raw))
    }

    private static func median(sortedValues v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        if v.count % 2 == 1 { return v[v.count / 2] }
        return (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    // MARK: - Whole-plan entry point

    /// Walks every body + cold-open clip in the plan, samples each one's
    /// mid-time mean RGB, computes the median target, returns a per-clip
    /// gain map keyed by ClipPlan.id. Off-thread; one AVAssetImageGenerator
    /// seek per clip — modest cost (a couple seconds for a 60 s reel).
    static func analyze(plan: EditPlan,
                        sourceURL: URL) async -> [UUID: ClipGain] {
        var clipIDs: [UUID] = []
        var midTimes: [Double] = []
        if let cold = plan.coldOpen {
            clipIDs.append(cold.id)
            midTimes.append((cold.sourceStart + cold.sourceEnd) / 2)
        }
        for clip in plan.body {
            clipIDs.append(clip.id)
            midTimes.append((clip.sourceStart + clip.sourceEnd) / 2)
        }
        guard !clipIDs.isEmpty else { return [:] }

        let asset = AVURLAsset(url: sourceURL)
        var means: [SIMD3<Float>] = []
        means.reserveCapacity(clipIDs.count)
        for t in midTimes {
            if let mean = await meanRGB(at: t, from: asset) {
                means.append(mean)
            } else {
                // Use a sentinel midgrey so the median still includes
                // this slot; clip's gain will end up identity-ish.
                means.append(SIMD3<Float>(0.5, 0.5, 0.5))
            }
        }
        let perClipGains = gains(forMeans: means)
        var out: [UUID: ClipGain] = [:]
        for (id, gain) in zip(clipIDs, perClipGains) {
            out[id] = gain
        }
        let nonIdentity = perClipGains.filter { !$0.isIdentity }.count
        logger.info("ColorMatch: \(perClipGains.count) clips, \(nonIdentity) corrected, max channel correction = \(maxChannelCorrection, format: .fixed(precision: 2))")
        return out
    }
}
