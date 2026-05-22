//
//  MetalPetalCompositor.swift
//  PlayerCut/Composition
//
//  ONE unified GPU render path for the cinematic reel. Every output
//  frame — body clips, A/B transitions, color grade, title / closing /
//  lower-third overlays — flows through a single MTIImage graph and
//  one MTIContext render. There is no AVVideoCompositionCoreAnimationTool
//  in the pipeline; mixing it with a custom AVVideoCompositing is an
//  Apple-API conflict that broke export on real devices (Section 2.1).
//
//  Per-frame:
//    1. Wrap source A frame in MTIImage.
//    2. Crop + scale per the EditPlan's interpolated keyframe.
//    3. Apply color grade (procedurally-generated LUT via MTI's color
//       lookup filter).
//    4. If in a transition window: wrap source B, repeat 2–3, blend.
//    5. If the instruction carries an overlay: composite the rasterized
//       title / closing / lower-third on top with time-varying alpha.
//    6. Render to the destination CVPixelBuffer.
//
//  Title-only spans (cold black between body clips) still produce a real
//  frame: we synthesize a black MTIImage so the overlay has something
//  to draw onto and the export pipeline always sees pixels.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import MetalPetal
import os.log

final class MetalPetalCompositor: NSObject, AVVideoCompositing {

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "MetalPetalCompositor")
    private let renderQueue = DispatchQueue(
        label: "playercut.compositor.mti.render",
        qos: .userInitiated)
    private let mtiContext: MTIContext?
    private var renderContext: AVVideoCompositionRenderContext?

    /// Cached MTIImage view of each ColorLook's LUT cube. Generated
    /// once from LUTFactory's procedural cube data and reused.
    private let lutCache = LUTImageCache()

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                self.mtiContext = try MTIContext(device: device)
            } catch {
                Logger(subsystem: "com.playercut.app",
                       category: "MetalPetalCompositor")
                    .error("MTIContext init failed: \(error.localizedDescription)")
                self.mtiContext = nil
            }
        } else {
            self.mtiContext = nil
        }
        super.init()
    }

    // MARK: - AVVideoCompositing required surface

    var sourcePixelBufferAttributes: [String: Any]? {
        [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferMetalCompatibilityKey): true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferMetalCompatibilityKey): true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.handle(request: asyncVideoCompositionRequest)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Stateless — nothing to clean up.
    }

    // MARK: - Frame render

    private func handle(request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
                as? MetalPetalInstruction,
              let dest = request.renderContext.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }

        let time = request.compositionTime.seconds
        let outputSize = request.renderContext.size

        // --- Source A ---------------------------------------------------
        // Title / closing card spans don't carry source video frames; we
        // synthesize a solid-black MTIImage of the right size so the
        // overlay composite has something to draw against.
        let aImage: MTIImage
        if let aBuffer = request.sourceFrame(byTrackID: instruction.trackAID) {
            aImage = processSource(buffer: aBuffer,
                                   instruction: instruction,
                                   atTime: time,
                                   outputSize: outputSize,
                                   useBSideCrop: false)
        } else {
            aImage = solidBlack(size: outputSize)
        }

        // --- Source B (transition only) --------------------------------
        var output = aImage
        if let blend = instruction.transitionForOutputTime(time),
           let bTrackID = instruction.trackBID,
           let bBuffer = request.sourceFrame(byTrackID: bTrackID) {
            let bImage = processSource(buffer: bBuffer,
                                       instruction: instruction,
                                       atTime: time,
                                       outputSize: outputSize,
                                       useBSideCrop: true)
            output = applyTransition(blend: blend,
                                     a: aImage,
                                     b: bImage,
                                     outputSize: outputSize)
        }

        // --- Overlay (title / closing / lower-third) -------------------
        if let overlay = instruction.overlay {
            let alpha = overlay.alphaAt(outputTime: time)
            if alpha > 0.001,
               let overlayImage = overlay.mtiImage {
                output = composite(over: output,
                                   overlay: overlayImage,
                                   alpha: alpha,
                                   outputSize: outputSize)
            }
        }

        // --- Render to destination --------------------------------------
        guard let mtiContext else {
            // No Metal device — best-effort passthrough. The export
            // pipeline still completes; the frame is just unprocessed.
            request.finish(withComposedVideoFrame: dest)
            return
        }
        do {
            try mtiContext.render(output, to: dest)
        } catch {
            log.error("MTI render failed: \(error.localizedDescription)")
        }
        request.finish(withComposedVideoFrame: dest)
    }

    // MARK: - Source processing

    /// Wraps a source CVPixelBuffer as an MTIImage, applies the
    /// EditPlan crop keyframe (or a centered passthrough for the B
    /// side during a transition), and the LUT color grade.
    private func processSource(buffer: CVPixelBuffer,
                               instruction: MetalPetalInstruction,
                               atTime time: Double,
                               outputSize: CGSize,
                               useBSideCrop: Bool) -> MTIImage {
        let image = MTIImage(cvPixelBuffer: buffer, alphaType: .alphaIsOne)

        // Crop + scale.
        let localTime = max(0, time - instruction.startSeconds)
        let key: CropKeyframe = useBSideCrop
            ? CropKeyframe(time: 0,
                           center: CGPoint(x: 0.5, y: 0.5),
                           scale: 1.0)
            : instruction.cropKeyframeAt(localTime: localTime)
        let cropped = cropAndFit(image: image,
                                 center: key.center,
                                 scale: key.scale,
                                 outputSize: outputSize)

        // Cinematic grade pipeline (Section 3). Order:
        //   1. (skipped: per-clip exposure/WB correction would land
        //       here — DEFERRED, requires a pre-pass over the source.)
        //   2. Apply the creative LUT to the (already cropped) source.
        //   3. Blend the LUT result with the unmodified cropped source
        //      at ~70 % opacity. // SOURCE: pixflow.net 2026-02-09 —
        //      pros apply creative LUTs at 60-80 % intensity, not full
        //      strength, so the look reads "dialed in" rather than
        //      "filter slapped on top."
        //   4. Polish: subtle MPS unsharp mask (no halos), gentle
        //      vignette via solid-color overlay (off for v1; covered
        //      by the vibe-specific LUTs already).
        let fullyGraded: MTIImage
        if let lutImage = lutCache.image(for: instruction.look) {
            let cube = MTIColorLookupFilter()
            cube.inputImage = cropped
            cube.inputColorLookupTable = lutImage
            fullyGraded = cube.outputImage ?? cropped
        } else {
            fullyGraded = cropped
        }
        // Blend graded ← 70% over cropped ← 30% via MTIBlendFilter.
        // MTIBlendFilter's intensity controls the foreground opacity.
        let lutBlendIntensity: Float = 0.70
        let blend = MTIBlendFilter(blendMode: .normal)
        blend.inputBackgroundImage = cropped
        blend.inputImage = fullyGraded
        blend.intensity = lutBlendIntensity
        let graded = blend.outputImage ?? fullyGraded

        // Polish: subtle MPS unsharp mask. radius 1.2, scale 0.35.
        // // SOURCE: pixflow.net 2026-02-09 — final pass is "subtle
        // // sharpen, no clipping."
        let unsharp = MTIMPSUnsharpMaskFilter()
        unsharp.inputImage = graded
        unsharp.radius = 1.2
        unsharp.scale = 0.35
        return unsharp.outputImage ?? graded
    }

    /// Center-crops + scales the source image to exactly `outputSize`.
    /// Honors the keyframe scale (1.0 = max fit; >1.0 zooms further).
    /// Clamps to source bounds so we never see black bars.
    private func cropAndFit(image: MTIImage,
                            center: CGPoint,
                            scale: CGFloat,
                            outputSize: CGSize) -> MTIImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return image }

        let outAspect = outputSize.width / outputSize.height
        let srcAspect = srcSize.width / srcSize.height

        var cropW: CGFloat
        var cropH: CGFloat
        if outAspect < srcAspect {
            cropH = srcSize.height
            cropW = cropH * outAspect
        } else {
            cropW = srcSize.width
            cropH = cropW / outAspect
        }
        let s = max(1.0, scale)
        cropW /= s
        cropH /= s

        let cx = clamp(center.x, lo: 0, hi: 1) * srcSize.width
        let cy = clamp(center.y, lo: 0, hi: 1) * srcSize.height
        var x = cx - cropW / 2
        var y = cy - cropH / 2
        x = clamp(x, lo: 0, hi: srcSize.width - cropW)
        y = clamp(y, lo: 0, hi: srcSize.height - cropH)
        let cropRect = CGRect(x: x, y: y, width: cropW, height: cropH)

        // MTICropFilter scales the cropped region by `scale` after
        // cutting it out; we use that to land exactly at outputSize.
        let crop = MTICropFilter()
        crop.cropRegion = .pixel(cropRect)
        crop.scale = Float(min(outputSize.width / cropW,
                               outputSize.height / cropH))
        crop.inputImage = image
        return crop.outputImage ?? image
    }

    // MARK: - Transitions

    private func applyTransition(blend: MetalPetalInstruction.TransitionBlend,
                                 a: MTIImage,
                                 b: MTIImage,
                                 outputSize: CGSize) -> MTIImage {
        let t = CGFloat(blend.progress)

        switch blend.kind {
        case .hardCut:
            return blend.progress < 0.5 ? a : b

        case .crossDissolve, .fadeFromBlack, .fadeToBlack:
            return dissolve(a: a, b: b, t: t)

        case .whipPan:
            // A slides off to the left with directional Gaussian blur;
            // B slides in from the right. We composite B over a blurred,
            // translated A using MultilayerCompositingFilter.
            let aMoved = translate(a, dx: -outputSize.width * t,
                                   outputSize: outputSize)
            let aBlur = motionBlur(aMoved, radius: 40 * t)
            let bMoved = translate(b, dx: outputSize.width * (1 - t),
                                   outputSize: outputSize)
            return composite(over: aBlur,
                             overlay: bMoved,
                             alpha: 1.0,
                             outputSize: outputSize)

        case .zoomPunch:
            let aZoomed = scaleAroundCenter(a, factor: 1.0 + 0.25 * t,
                                            outputSize: outputSize)
            let bZoomed = scaleAroundCenter(b, factor: 1.15 - 0.15 * t,
                                            outputSize: outputSize)
            return dissolve(a: aZoomed, b: bZoomed, t: t)

        case .lightLeakWipe:
            // Cross-dissolve underneath a warm additive flash that
            // peaks at t=0.5.
            let base = dissolve(a: a, b: b, t: t)
            let flash = max(0, 1 - abs(t - 0.5) * 2)
            if flash <= 0.01 { return base }
            let warm = solidColor(red: 1.0, green: 0.78, blue: 0.45,
                                  alpha: 1.0,
                                  size: outputSize)
            return composite(over: base,
                             overlay: warm,
                             alpha: 0.7 * flash,
                             outputSize: outputSize)
        }
    }

    private func dissolve(a: MTIImage, b: MTIImage, t: CGFloat) -> MTIImage {
        let blend = MTIBlendFilter(blendMode: .normal)
        blend.inputBackgroundImage = a
        blend.inputImage = b
        blend.intensity = Float(t)
        return blend.outputImage ?? a
    }

    /// Composites `overlay` over `base` at `alpha` opacity. Both images
    /// are expected to be `outputSize` already.
    private func composite(over base: MTIImage,
                           overlay: MTIImage,
                           alpha: CGFloat,
                           outputSize: CGSize) -> MTIImage {
        let layer = MultilayerCompositingFilter.Layer(content: overlay)
            .frame(CGRect(origin: .zero, size: outputSize),
                   layoutUnit: .pixel)
            .opacity(Float(alpha))
        let comp = MultilayerCompositingFilter()
        comp.inputBackgroundImage = base
        comp.layers = [layer]
        return comp.outputImage ?? base
    }

    private func translate(_ image: MTIImage,
                           dx: CGFloat,
                           outputSize: CGSize) -> MTIImage {
        let t = MTITransformFilter()
        t.inputImage = image
        t.transform = CATransform3DMakeTranslation(dx, 0, 0)
        t.viewport = CGRect(origin: .zero, size: outputSize)
        return t.outputImage ?? image
    }

    private func scaleAroundCenter(_ image: MTIImage,
                                   factor: CGFloat,
                                   outputSize: CGSize) -> MTIImage {
        let cx = outputSize.width / 2
        let cy = outputSize.height / 2
        var x = CATransform3DMakeTranslation(cx, cy, 0)
        x = CATransform3DScale(x, factor, factor, 1)
        x = CATransform3DTranslate(x, -cx, -cy, 0)
        let t = MTITransformFilter()
        t.inputImage = image
        t.transform = x
        t.viewport = CGRect(origin: .zero, size: outputSize)
        return t.outputImage ?? image
    }

    private func motionBlur(_ image: MTIImage, radius: CGFloat) -> MTIImage {
        guard radius > 0.5 else { return image }
        let blur = MTIMPSGaussianBlurFilter()
        blur.inputImage = image
        blur.radius = Float(min(40, radius))
        return blur.outputImage ?? image
    }

    private func solidBlack(size: CGSize) -> MTIImage {
        solidColor(red: 0, green: 0, blue: 0, alpha: 1, size: size)
    }

    private func solidColor(red: CGFloat, green: CGFloat,
                            blue: CGFloat, alpha: CGFloat,
                            size: CGSize) -> MTIImage {
        let color = MTIColor(red: Float(red),
                             green: Float(green),
                             blue: Float(blue),
                             alpha: Float(alpha))
        return MTIImage(color: color, sRGB: false, size: size)
    }

    private func clamp<T: Comparable>(_ v: T, lo: T, hi: T) -> T {
        min(max(v, lo), hi)
    }
}

// MARK: - LUT image cache

/// Wraps the procedurally-generated cube data from LUTFactory in a
/// `MTIImage` suitable for `MTIColorLookupFilter.inputColorLookupTable`.
/// MetalPetal expects the LUT as a square 2D image (cube unrolled),
/// not as raw cube data — we synthesize it once per ColorLook and cache.
final class LUTImageCache {

    private let cubeDim = LUTFactory.cubeDimension
    private var cache: [ColorLook: MTIImage] = [:]
    private let lock = NSLock()

    func image(for look: ColorLook) -> MTIImage? {
        lock.lock()
        if let cached = cache[look] { lock.unlock(); return cached }
        lock.unlock()

        guard let image = synthesize(for: look) else { return nil }
        lock.lock()
        cache[look] = image
        lock.unlock()
        return image
    }

    /// LUTFactory hands us raw RGBA floats laid out as dim×dim×dim×4.
    /// MetalPetal's color-lookup filter wants a 2-D image of size
    /// (dim × dim) by (dim) — unrolled "horizontal strips of blue
    /// slices" where x = b*dim + r, y = g.
    private func synthesize(for look: ColorLook) -> MTIImage? {
        let data = LUTFactory.data(for: look)
        let dim = cubeDim
        let bytesPerPixel = 4
        let width = dim * dim
        let height = dim
        var rgba8 = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let f = rawPtr.bindMemory(to: Float.self)
            for b in 0..<dim {
                for g in 0..<dim {
                    for r in 0..<dim {
                        let srcIndex = ((b * dim + g) * dim + r) * 4
                        let dstX = b * dim + r
                        let dstY = g
                        let dstIndex = (dstY * width + dstX) * 4
                        rgba8[dstIndex + 0] = clamp8(f[srcIndex + 0])
                        rgba8[dstIndex + 1] = clamp8(f[srcIndex + 1])
                        rgba8[dstIndex + 2] = clamp8(f[srcIndex + 2])
                        rgba8[dstIndex + 3] = 255
                    }
                }
            }
        }

        guard let provider = CGDataProvider(
            data: Data(rgba8) as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: width * bytesPerPixel,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent) else { return nil }
        return MTIImage(cgImage: cg, isOpaque: true)
    }

    private func clamp8(_ f: Float) -> UInt8 {
        let v = max(0, min(1, f))
        return UInt8(v * 255)
    }
}

// MARK: - Instruction

/// One AVVideoCompositionInstruction worth of render-time decisions.
/// Replaces the old `CinematicInstruction` — same shape plus an
/// optional `overlay` so the unified render path can draw title /
/// closing / lower-third cards without AVVideoCompositionCoreAnimationTool.
final class MetalPetalInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    struct TransitionBlend {
        var kind: TransitionKind
        var progress: Double   // 0..1 across the transition window
    }

    /// Rasterized overlay (title / closing / lower-third). Carries its
    /// own alpha schedule so the compositor can fade it in/out without
    /// needing CALayer animations.
    struct Overlay {
        var mtiImage: MTIImage?
        /// Output time when the overlay first appears.
        var startTime: Double
        /// Output time when the overlay is fully gone.
        var endTime: Double
        /// Fade-in duration (seconds).
        var fadeIn: Double
        /// Fade-out duration (seconds).
        var fadeOut: Double

        func alphaAt(outputTime t: Double) -> CGFloat {
            guard t >= startTime, t <= endTime else { return 0 }
            let local = t - startTime
            let span = endTime - startTime
            if local < fadeIn {
                return CGFloat(local / max(0.001, fadeIn))
            }
            let outStart = span - fadeOut
            if local > outStart {
                let f = (local - outStart) / max(0.001, fadeOut)
                return CGFloat(1.0 - f)
            }
            return 1.0
        }
    }

    let timeRange: CMTimeRange
    let trackAID: CMPersistentTrackID
    let trackBID: CMPersistentTrackID?
    let cropKeyframes: [CropKeyframe]
    let look: ColorLook
    let startSeconds: Double
    let transitionKind: TransitionKind?
    let transitionStart: Double?
    let transitionEnd: Double?
    let overlay: Overlay?

    init(timeRange: CMTimeRange,
         startSeconds: Double,
         trackAID: CMPersistentTrackID,
         trackBID: CMPersistentTrackID?,
         cropKeyframes: [CropKeyframe],
         look: ColorLook,
         transitionKind: TransitionKind?,
         transitionStart: Double?,
         transitionEnd: Double?,
         overlay: Overlay? = nil) {
        self.timeRange = timeRange
        self.startSeconds = startSeconds
        self.trackAID = trackAID
        self.trackBID = trackBID
        self.cropKeyframes = cropKeyframes
        self.look = look
        self.transitionKind = transitionKind
        self.transitionStart = transitionStart
        self.transitionEnd = transitionEnd
        self.overlay = overlay
        super.init()
    }

    var enablePostProcessing: Bool { false }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? {
        var ids: [NSValue] = [NSNumber(value: trackAID)]
        if let b = trackBID { ids.append(NSNumber(value: b)) }
        return ids
    }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    func cropKeyframeAt(localTime t: Double) -> CropKeyframe {
        guard !cropKeyframes.isEmpty else {
            return CropKeyframe(time: 0,
                                center: CGPoint(x: 0.5, y: 0.5),
                                scale: 1.0)
        }
        if t <= cropKeyframes[0].time { return cropKeyframes[0] }
        if t >= cropKeyframes.last!.time { return cropKeyframes.last! }
        for i in 0..<(cropKeyframes.count - 1) {
            let a = cropKeyframes[i]
            let b = cropKeyframes[i + 1]
            if t >= a.time && t <= b.time {
                let span = max(1e-6, b.time - a.time)
                let f = CGFloat((t - a.time) / span)
                let c = CGPoint(x: a.center.x + (b.center.x - a.center.x) * f,
                                y: a.center.y + (b.center.y - a.center.y) * f)
                let s = a.scale + (b.scale - a.scale) * f
                return CropKeyframe(time: t, center: c, scale: s)
            }
        }
        return cropKeyframes.last!
    }

    func transitionForOutputTime(_ time: Double) -> TransitionBlend? {
        guard let kind = transitionKind,
              let s = transitionStart, let e = transitionEnd,
              time >= s, time <= e else { return nil }
        let span = max(1e-6, e - s)
        return TransitionBlend(kind: kind,
                               progress: (time - s) / span)
    }
}
