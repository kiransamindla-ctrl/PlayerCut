//
//  Stage2ResolutionTests.swift
//  PlayerCutTests
//
//  Validates the PR #10 dual-resolution Stage 2 path: 480-px primary
//  loop for cheap Vision (HumanRect / FaceQuality / FeaturePrint /
//  BodyPose / HSV) + native-res OCR-only seek + face-quality fallback.
//
//  We can't run real human detection in the sim — the synthetic sample
//  has no humans — so these tests cover the contract you'd otherwise
//  silently break in the refactor: the normalized box returned by the
//  480p detector must map to the same source region at native res.
//

import AVFoundation
import CoreVideo
import Vision
import XCTest
@testable import PlayerCut

@MainActor
final class Stage2ResolutionTests: XCTestCase {

    // MARK: - Cross-resolution crop invariant

    /// A VNHumanObservation with a normalized bbox of (0.4, 0.4, 0.2, 0.4)
    /// must crop the SAME source region from a 480-px and a 1280-px image.
    /// The OCR-resolution crop in PR #10's Stage 2 relies on this — it
    /// reuses the detection's normalized box on a native-res frame.
    func testCropPersonCoversSameRegionAcrossResolutions() throws {
        let bbox = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.4)

        let smallW = 480
        let largeW = 1280
        // Square images so the aspect-multiplication is unambiguous.
        let small = try makeSolidImage(width: smallW, height: smallW)
        let large = try makeSolidImage(width: largeW, height: largeW)

        let smallCrop = try XCTUnwrap(
            crop(image: small, normalized: bbox),
            "small-image crop must succeed")
        let largeCrop = try XCTUnwrap(
            crop(image: large, normalized: bbox),
            "large-image crop must succeed")

        // Same fraction of the source frame → matching aspect + matching
        // size ratio. The pixel counts scale by (1280/480)² = ~7.1.
        let ratioW = Double(largeCrop.width) / Double(smallCrop.width)
        let ratioH = Double(largeCrop.height) / Double(smallCrop.height)
        XCTAssertEqual(ratioW, Double(largeW) / Double(smallW), accuracy: 0.05,
                       "OCR-res crop width must scale with the source width ratio")
        XCTAssertEqual(ratioH, Double(largeW) / Double(smallW), accuracy: 0.05,
                       "OCR-res crop height must scale with the source height ratio")

        // Aspect within each crop must match the bbox aspect (0.5).
        let bboxAspect = bbox.width / bbox.height
        XCTAssertEqual(Double(smallCrop.width) / Double(smallCrop.height),
                       bboxAspect, accuracy: 0.05)
        XCTAssertEqual(Double(largeCrop.width) / Double(largeCrop.height),
                       bboxAspect, accuracy: 0.05)
    }

    /// A bounding box pinned to the top edge (Vision's y origin is the
    /// BOTTOM, ours is the top) must crop the actual top of the image,
    /// not the bottom. PR #10's OCR carve-out reuses cropPerson — a
    /// flipped axis here would silently OCR the wrong half of the frame.
    func testCropPersonRespectsVisionYAxisFlip() throws {
        let img = try makePaintedTopHalfImage(width: 200, height: 200)
        // Vision-style bbox covering the TOP half (y=0.5..1.0).
        let topBbox = CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
        let topCrop = try XCTUnwrap(crop(image: img, normalized: topBbox))
        let topPixel = try samplePixel(topCrop, x: 100, y: 10)
        XCTAssertEqual(topPixel.r, 255, accuracy: 5,
                       "Vision-y=0.5..1 must crop the painted top half (red); got R=\(topPixel.r)")

        // Vision-style bbox covering the BOTTOM half (y=0..0.5).
        let botBbox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5)
        let botCrop = try XCTUnwrap(crop(image: img, normalized: botBbox))
        let botPixel = try samplePixel(botCrop, x: 100, y: 10)
        XCTAssertLessThan(botPixel.r, 50,
                          "Vision-y=0..0.5 must crop the unpainted bottom half; got R=\(botPixel.r)")
    }

    // MARK: - Test helpers

    /// Mirrors Stage2PlayerLocalizer.cropPerson: takes a normalized
    /// Vision-coord bbox + a CGImage, returns the cropped CGImage.
    private func crop(image: CGImage, normalized: CGRect) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let rect = CGRect(x: normalized.origin.x * imgW,
                          y: (1 - normalized.origin.y - normalized.height) * imgH,
                          width: normalized.width * imgW,
                          height: normalized.height * imgH)
        return image.cropping(to: rect)
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx?.makeImage(), "solid context image")
    }

    /// Image painted RED in the TOP half (Core Graphics y=0 is at the top),
    /// black in the bottom. Used to confirm the Vision-y flip.
    private func makePaintedTopHalfImage(width: Int, height: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // Black background.
        ctx?.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext's default y axis is bottom-up; the resulting CGImage
        // is top-down. Painting at y=h/2..h fills the UPPER half of the
        // emitted CGImage (which is what we want for the Vision-y test).
        ctx?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return try XCTUnwrap(ctx?.makeImage(), "painted context image")
    }

    private struct RGB { let r: Int; let g: Int; let b: Int }

    private func samplePixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
        // Rasterize the entire image into a known-orientation buffer
        // (y=0 at top, row-major) so we can sample directly by index.
        let w = image.width
        let h = image.height
        let rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &buf,
                            width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: rowBytes,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = y * rowBytes + x * 4
        return RGB(r: Int(buf[i]),
                   g: Int(buf[i + 1]),
                   b: Int(buf[i + 2]))
    }
}
