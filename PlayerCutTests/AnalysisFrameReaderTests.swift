//
//  AnalysisFrameReaderTests.swift
//  PlayerCutTests
//
//  Validates the downscaling / aspect-ratio / stride math for the
//  AnalysisFrameReader (Sections 4 + 5). Pixel-pipeline tests use
//  the SampleVideoFactory so the suite runs without device assets.
//

import AVFoundation
import XCTest
@testable import PlayerCut

final class AnalysisFrameReaderTests: XCTestCase {

    // MARK: - Pure target-size math

    func testTargetSizeLandscape1920x1080() {
        let (w, h) = AnalysisFrameReader.targetSize(
            width: 1920, height: 1080, longEdge: 480)
        XCTAssertEqual(w, 480, "long edge must be exactly the requested 480 px")
        // 1080 / 1920 * 480 = 270, even.
        XCTAssertEqual(h, 270, accuracy: 1, "aspect ratio must be preserved")
    }

    func testTargetSizePortrait1080x1920() {
        let (w, h) = AnalysisFrameReader.targetSize(
            width: 1080, height: 1920, longEdge: 480)
        XCTAssertEqual(h, 480, "portrait long edge is height")
        XCTAssertEqual(w, 270, accuracy: 1)
    }

    func testTargetSizeSquareSourceUsesLongEdgeForBoth() {
        let (w, h) = AnalysisFrameReader.targetSize(
            width: 1000, height: 1000, longEdge: 360)
        XCTAssertEqual(w, 360)
        XCTAssertEqual(h, 360)
    }

    func testTargetSizeRoundsToEvenDimensions() {
        // 1280 x 537 (odd height) at longEdge 480 → 480 x 201.375 → 202
        let (w, h) = AnalysisFrameReader.targetSize(
            width: 1280, height: 537, longEdge: 480)
        XCTAssertEqual(Int(w) % 2, 0, "width must be even (\(w))")
        XCTAssertEqual(Int(h) % 2, 0, "height must be even (\(h))")
    }

    // MARK: - Live decode against a synthetic source

    func testReaderProducesDownscaledFrames() async throws {
        // SampleVideoFactory writes 1080×1920 by default; we ask the
        // reader for 480 long edge → expect 270×480 frames.
        let spec = SampleVideoFactory.Spec(durationSeconds: 2)
        let url = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = AnalysisFrameReader(url: url, longEdge: 480, stride: 1)
        try await reader.start()

        guard let frame = await reader.next() else {
            XCTFail("reader produced no frames")
            return
        }
        XCTAssertLessThanOrEqual(max(frame.width, frame.height), 480,
                                 "long edge must not exceed the requested 480 px")
        XCTAssertGreaterThan(min(frame.width, frame.height), 200,
                             "short edge must be > 0 after aspect-preserving scale")
        await reader.cancel()
    }

    func testStrideHonored() async throws {
        let spec = SampleVideoFactory.Spec(durationSeconds: 2)  // ~60 frames at 30 fps
        let url = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: url) }

        // Stride 4 → ~15 emitted from ~60 source frames.
        let reader = AnalysisFrameReader(url: url, longEdge: 480, stride: 4)
        try await reader.start()
        var emitted = 0
        while let _ = await reader.next() { emitted += 1 }
        let skipped = await reader.skippedByStride
        let producedRatio = Double(emitted) / Double(emitted + skipped)
        XCTAssertEqual(producedRatio, 0.25, accuracy: 0.10,
                       "stride 4 must emit ~1-in-4 frames (got \(producedRatio))")
    }

    func testPresetFaceStrideIs8() {
        let reader = AnalysisFrameReader(url: URL(fileURLWithPath: "/tmp/x.mov"),
                                         preset: .faceQuality)
        XCTAssertEqual(reader.stride, 8)
    }

    func testPresetMotionStrideIs4() {
        let reader = AnalysisFrameReader(url: URL(fileURLWithPath: "/tmp/x.mov"),
                                         preset: .motion)
        XCTAssertEqual(reader.stride, 4)
    }

    func testReaderRejectsAssetWithoutVideo() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-video-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 128).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let reader = AnalysisFrameReader(url: bogus)
        do {
            try await reader.start()
            XCTFail("expected start() to throw for a non-video asset")
        } catch {
            // expected
        }
    }
}
