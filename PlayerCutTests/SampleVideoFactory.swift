//
//  SampleVideoFactory.swift
//  PlayerCutTests
//
//  Generates a real, playable H.264 .mov on disk for simulator-side
//  pipeline tests. The simulator has no camera — but every analysis and
//  composition stage operates on a video FILE, not a live capture
//  session. A synthesized file therefore lets the whole reel pipeline
//  (ingest → reframe/grade → speed ramps → transitions → audio mix →
//  export) run on the simulator with no camera and no committed binary
//  blob in the repo.
//
//  The frame content is a bright jersey-colored "player" rectangle
//  tracking a path across a dark field plus a fast-moving "ball", so:
//    - VNGenerateOpticalFlowRequest (Stage 1) sees real inter-frame
//      motion, and
//    - the auto-reframe crop has a subject whose center actually moves.
//

import AVFoundation
import CoreGraphics
import Foundation
@testable import PlayerCut

enum SampleVideoFactory {

    struct Spec {
        var size = CGSize(width: 1280, height: 720)   // 16:9 landscape, like a phone camera
        var fps: Int32 = 30
        var durationSeconds: Double = 8
    }

    enum FactoryError: Error, CustomStringConvertible {
        case writerSetupFailed(String)
        case pixelBufferPoolFailed
        case contextFailed
        case appendFailed(String)

        var description: String {
            switch self {
            case .writerSetupFailed(let m): return "AVAssetWriter setup failed: \(m)"
            case .pixelBufferPoolFailed:    return "pixel buffer pool unavailable"
            case .contextFailed:            return "CGContext creation failed"
            case .appendFailed(let m):      return "frame append failed: \(m)"
            }
        }
    }

    /// Writes a synthesized .mov to a unique temp URL and returns it.
    static func makeSampleVideo(spec: Spec = Spec()) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playercut-sample-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: url, fileType: .mov)
        } catch {
            throw FactoryError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(spec.size.width),
            AVVideoHeightKey: Int(spec.size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(spec.size.width),
            kCVPixelBufferHeightKey as String: Int(spec.size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: pbAttrs)

        guard writer.canAdd(input) else {
            throw FactoryError.writerSetupFailed("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FactoryError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(2, Int(spec.durationSeconds * Double(spec.fps)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)   // 2 ms backpressure
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw FactoryError.pixelBufferPoolFailed
            }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw FactoryError.pixelBufferPoolFailed }

            CVPixelBufferLockBaseAddress(pb, [])
            guard let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: Int(spec.size.width),
                height: Int(spec.size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                CVPixelBufferUnlockBaseAddress(pb, [])
                throw FactoryError.contextFailed
            }
            draw(frame: frame, total: totalFrames, in: ctx, size: spec.size)
            CVPixelBufferUnlockBaseAddress(pb, [])

            let pts = CMTime(value: CMTimeValue(frame), timescale: spec.fps)
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw FactoryError.appendFailed(
                    writer.error?.localizedDescription ?? "append frame \(frame)")
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else {
            throw FactoryError.appendFailed(
                writer.error?.localizedDescription
                    ?? "finishWriting ended in status \(writer.status.rawValue)")
        }
        return url
    }

    private static func draw(frame: Int, total: Int,
                             in ctx: CGContext, size: CGSize) {
        let t = Double(frame) / Double(max(1, total - 1))
        // Dark green "field".
        ctx.setFillColor(red: 0.05, green: 0.18, blue: 0.08, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        // The "player": a bright jersey-colored rect moving diagonally.
        let pw = size.width * 0.09
        let ph = size.height * 0.22
        let px = size.width * (0.15 + 0.60 * t)
        let py = size.height * (0.30 + 0.25 * sin(t * .pi))
        ctx.setFillColor(red: 1.0, green: 0.42, blue: 0.12, alpha: 1)   // orange jersey
        ctx.fill(CGRect(x: px, y: py, width: pw, height: ph))
        // A small fast "ball" so optical flow has high-frequency motion.
        let bx = size.width * (0.90 - 0.80 * t)
        let by = size.height * (0.50 + 0.35 * cos(t * 2 * .pi))
        ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.90, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: bx, y: by, width: 26, height: 26))
    }

    /// Bounding boxes (Vision coords: normalized, origin bottom-left)
    /// that follow the drawn player path, so EditPlanBuilder emits real
    /// subject-follow reframe keyframes rather than the Ken Burns
    /// fallback.
    static func playerBoxes(start: Double, end: Double,
                            count: Int = 10) -> [TimedBox] {
        (0...count).map { i in
            let f = Double(i) / Double(count)
            let t = start + (end - start) * f
            let x = 0.15 + 0.60 * f                       // mirrors draw()'s px
            let topUIKit = 0.30 + 0.25 * sin(f * .pi)     // UIKit top-left origin
            let h = 0.22
            let yVision = max(0, 1.0 - topUIKit - h)       // → bottom-left origin
            return TimedBox(time: t,
                            box: CGRect(x: x, y: yVision, width: 0.09, height: h))
        }
    }
}
