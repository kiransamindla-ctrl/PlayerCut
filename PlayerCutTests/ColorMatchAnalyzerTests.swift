//
//  ColorMatchAnalyzerTests.swift
//  PlayerCutTests
//
//  Validates PR #11 S3 — per-clip auto color match.
//

import CoreGraphics
import simd
import XCTest
@testable import PlayerCut

final class ColorMatchAnalyzerTests: XCTestCase {

    // MARK: - Pure mean RGB extraction

    func testMeanRGBOfSolidRedImageIsRed() throws {
        let cg = try makeSolidImage(r: 200, g: 50, b: 100, side: 32)
        let mean = try XCTUnwrap(ColorMatchAnalyzer.meanRGB(from: cg))
        XCTAssertEqual(mean.x, 200.0 / 255, accuracy: 0.01)
        XCTAssertEqual(mean.y,  50.0 / 255, accuracy: 0.01)
        XCTAssertEqual(mean.z, 100.0 / 255, accuracy: 0.01)
    }

    // MARK: - Gain math + median target

    /// Two clips: one "sunlit" (high red), one "shaded" (low red). The
    /// reel-wide median sits between them; gains nudge each toward the
    /// median → post-match variance MUST drop.
    func testGainsReduceClipToClipVariance() {
        let sun   = SIMD3<Float>(0.85, 0.65, 0.55)   // warm sun
        let shade = SIMD3<Float>(0.55, 0.50, 0.60)   // cool shade
        let means = [sun, shade]
        let gains = ColorMatchAnalyzer.gains(forMeans: means)
        XCTAssertEqual(gains.count, 2)

        // Apply the gains to the original means → post-match means.
        let postSun = SIMD3<Float>(
            sun.x   * gains[0].r,
            sun.y   * gains[0].g,
            sun.z   * gains[0].b)
        let postShade = SIMD3<Float>(
            shade.x * gains[1].r,
            shade.y * gains[1].g,
            shade.z * gains[1].b)

        let preVariance = variance(means)
        let postVariance = variance([postSun, postShade])
        XCTAssertLessThan(postVariance, preVariance,
                          "post-match per-channel variance must drop (pre=\(preVariance), post=\(postVariance))")
    }

    /// A near-black clip's gain must NOT raise it above the cap.
    /// Per spec the correction is capped at ±18 % per channel so the
    /// black clip isn't blown out into a different exposure.
    func testCorrectionCapsAtChannelCeiling() {
        // Reel-wide median sits around 0.60; the dark clip sits at 0.05.
        let dark  = SIMD3<Float>(0.05, 0.05, 0.05)
        let bright = SIMD3<Float>(0.70, 0.70, 0.70)
        let medium = SIMD3<Float>(0.50, 0.50, 0.50)
        let gains = ColorMatchAnalyzer.gains(forMeans: [dark, medium, bright])

        let darkGain = gains[0]
        // Raw uncapped gain would be 0.50 / 0.05 = 10×. Cap is 1.18.
        XCTAssertLessThanOrEqual(
            darkGain.r,
            1 + ColorMatchAnalyzer.maxChannelCorrection + 0.001,
            "near-black clip cannot exceed +18% per channel — got \(darkGain.r)")
        XCTAssertGreaterThanOrEqual(
            darkGain.r,
            1 - ColorMatchAnalyzer.maxChannelCorrection - 0.001,
            "gain must also respect the lower cap")
    }

    func testCappedGainIdentityWhenSourceEqualsTarget() {
        let g = ColorMatchAnalyzer.cappedGain(target: 0.5, source: 0.5)
        XCTAssertEqual(g, 1.0, accuracy: 0.001,
                       "source == target must yield identity gain")
    }

    func testCappedGainClampsAboveCeiling() {
        let g = ColorMatchAnalyzer.cappedGain(target: 1.0, source: 0.1)
        // raw = 10×, must clamp to 1.18.
        XCTAssertEqual(g, 1 + ColorMatchAnalyzer.maxChannelCorrection,
                       accuracy: 0.001)
    }

    func testCappedGainClampsBelowFloor() {
        let g = ColorMatchAnalyzer.cappedGain(target: 0.05, source: 1.0)
        // raw = 0.05, must clamp to 0.82.
        XCTAssertEqual(g, 1 - ColorMatchAnalyzer.maxChannelCorrection,
                       accuracy: 0.001)
    }

    // MARK: - ClipGain.isIdentity sentinel

    func testIdentityGainIsRecognized() {
        XCTAssertTrue(ColorMatchAnalyzer.ClipGain.identity.isIdentity)
        XCTAssertTrue(ColorMatchAnalyzer.ClipGain(r: 1.001, g: 1, b: 0.999).isIdentity,
                      "1% jitter still counts as identity")
        XCTAssertFalse(ColorMatchAnalyzer.ClipGain(r: 1.05, g: 1, b: 1).isIdentity,
                       "5% drift is NOT identity")
    }

    // MARK: - Helpers

    private func variance(_ samples: [SIMD3<Float>]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(SIMD3<Float>(repeating: 0), +) / Float(samples.count)
        let sq = samples.reduce(Float(0)) { acc, s in
            let d = s - mean
            return acc + (d.x * d.x + d.y * d.y + d.z * d.z)
        }
        return sq / Float(samples.count)
    }

    private func makeSolidImage(r: UInt8, g: UInt8, b: UInt8, side: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil,
                            width: side, height: side,
                            bitsPerComponent: 8,
                            bytesPerRow: side * 4,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(red: CGFloat(r) / 255,
                          green: CGFloat(g) / 255,
                          blue: CGFloat(b) / 255,
                          alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(ctx?.makeImage())
    }
}
