//
//  PixelBufferPool.swift
//  PlayerCut/Performance
//
//  Recycles CVPixelBuffer allocations. The naive approach in Stage 1 of the
//  scaffold allocates a fresh 320×180 buffer for every optical-flow frame —
//  that's ~10,800 allocations for a 90-min game at 2 fps, plus 2× as much
//  for Stage 2. CVPixelBuffer allocation is not free; pools cut steady-state
//  CPU by ~15% and reduce memory pressure significantly.
//
//  The pool is keyed on (width, height, pixelFormat). A typical pipeline
//  needs three pool sizes: analysis proxy (320x180), Stage 2 frame
//  (1280x720), and OCR upscale (variable). Hold one pool per size on the
//  pipeline, not one global pool.
//

import CoreVideo
import Foundation
import os.log

final class PixelBufferPool: @unchecked Sendable {

    private let log = Logger(subsystem: "com.playercut.app", category: "PixelPool")
    private var pool: CVPixelBufferPool?
    private let attributes: [CFString: Any]
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let lock = NSLock()

    /// `bufferCapacity` is the soft target — the pool may hold up to this
    /// many recycled buffers. Excess buffers are returned to the OS when the
    /// retain count drops to 1.
    init(width: Int,
         height: Int,
         pixelFormat: OSType = kCVPixelFormatType_32BGRA,
         bufferCapacity: Int = 6) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat

        self.attributes = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true
        ]

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: bufferCapacity
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             attributes as CFDictionary,
                                             &pool)
        if status != kCVReturnSuccess {
            log.error("Pool creation failed: status=\(status)")
        }
        self.pool = pool
    }

    /// Acquires a buffer. The returned buffer auto-recycles when its last
    /// reference drops, BUT only if you don't escape it from the pipeline.
    /// Don't store these in long-lived properties.
    func acquire() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let pool else { return nil }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                        pool,
                                                        &buffer)
        if status != kCVReturnSuccess {
            log.warning("Pool exhausted (status=\(status)); falling back to direct allocation")
            return directAllocate()
        }
        return buffer
    }

    /// Used as a fallback when the pool is briefly exhausted (e.g., the
    /// downstream Vision request hasn't yet released the previous frame).
    private func directAllocate() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                            attributes as CFDictionary, &buffer)
        return buffer
    }

    /// Drains buffers held by the pool. Call on memory pressure warnings.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard let pool else { return }
        CVPixelBufferPoolFlush(pool, .excessBuffers)
    }
}

// MARK: - CGImage → pooled CVPixelBuffer

extension PixelBufferPool {
    /// Draws a CGImage into a pooled buffer. Used heavily by Stage 1 (every
    /// optical-flow frame goes through this path). The CGContext setup is
    /// the slowest part — there's no clean way to pool that, but it's
    /// cheap relative to the alloc that this avoids.
    func makeBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        guard let buffer = acquire() else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
