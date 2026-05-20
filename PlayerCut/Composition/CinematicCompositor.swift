//
//  CinematicCompositor.swift
//  PlayerCut/Composition
//
//  Custom AVVideoCompositing that renders each frame through a Core
//  Image pipeline: source pixels → cropped + scaled per the EditPlan's
//  keyframes → color graded via a Vivid/Natural LUT → blended with the
//  next clip's frame when in a transition window.
//
//  Per-instruction state is carried in CinematicInstruction. The
//  compositor itself is stateless (modulo a CIContext) and thread-safe
//  for AVFoundation's render queue.
//

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import os.log

final class CinematicCompositor: NSObject, AVVideoCompositing {

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "CinematicCompositor")
    private let renderQueue = DispatchQueue(
        label: "playercut.compositor.render",
        qos: .userInitiated)
    private let ciContext: CIContext
    private var renderContext: AVVideoCompositionRenderContext?

    override init() {
        // Metal backing for the CIContext when available; the system
        // falls back to software if not, which is still acceptable for
        // a per-clip compose.
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device,
                                       options: [.workingColorSpace: NSNull()])
        } else {
            self.ciContext = CIContext(options: [.workingColorSpace: NSNull()])
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
                as? CinematicInstruction,
              let dest = request.renderContext.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }

        let time = request.compositionTime.seconds
        let outputSize = request.renderContext.size

        // Source A: the primary track for this instruction.
        guard let aBuffer = request.sourceFrame(byTrackID: instruction.trackAID) else {
            request.finish(withComposedVideoFrame: dest)
            return
        }
        var aImage = CIImage(cvPixelBuffer: aBuffer)
        aImage = applyCropAndGrade(image: aImage,
                                   instruction: instruction,
                                   atTime: time,
                                   outputSize: outputSize)

        // Source B (next clip), only present in a transition window.
        var blended = aImage
        if let bTrackID = instruction.trackBID,
           let bBuffer = request.sourceFrame(byTrackID: bTrackID),
           let blend = instruction.transitionForOutputTime(time) {
            var bImage = CIImage(cvPixelBuffer: bBuffer)
            bImage = applyCropAndGrade(image: bImage,
                                       instruction: instruction.flipped(),
                                       atTime: time,
                                       outputSize: outputSize)
            blended = applyTransition(blend: blend,
                                      a: aImage,
                                      b: bImage,
                                      outputSize: outputSize)
        }

        // Render to destination buffer.
        ciContext.render(blended,
                         to: dest,
                         bounds: CGRect(origin: .zero, size: outputSize),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: dest)
    }

    // MARK: - Crop + grade

    private func applyCropAndGrade(image: CIImage,
                                   instruction: CinematicInstruction,
                                   atTime time: Double,
                                   outputSize: CGSize) -> CIImage {

        let local = max(0, time - instruction.startSeconds)
        let key = instruction.cropKeyframeAt(localTime: local)
        let cropped = cropAndFit(image: image,
                                 center: key.center,
                                 scale: key.scale,
                                 outputSize: outputSize)

        // Color grade via cached LUT.
        let cubeData = LUTFactory.data(for: instruction.look)
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.cubeDimension = Float(LUTFactory.cubeDimension)
        cube.cubeData = cubeData
        cube.colorSpace = CGColorSpaceCreateDeviceRGB()
        cube.inputImage = cropped
        let graded = cube.outputImage ?? cropped

        // Subtle vignette (default ON; cheap and adds depth).
        let vig = CIFilter.vignette()
        vig.inputImage = graded
        vig.intensity = 0.55
        vig.radius = Float(min(outputSize.width, outputSize.height)) * 0.55
        return vig.outputImage ?? graded
    }

    private func cropAndFit(image: CIImage,
                            center: CGPoint,
                            scale: CGFloat,
                            outputSize: CGSize) -> CIImage {
        let srcExtent = image.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return image }
        let outAspect = outputSize.width / outputSize.height
        let srcAspect = srcExtent.width / srcExtent.height

        // Maximum-fit crop window in source pixels for the target aspect.
        var cropW: CGFloat
        var cropH: CGFloat
        if outAspect < srcAspect {
            cropH = srcExtent.height
            cropW = cropH * outAspect
        } else {
            cropW = srcExtent.width
            cropH = cropW / outAspect
        }
        // Apply the keyframe scale (1.0 = max fit; > 1.0 = tighter).
        cropW /= max(1.0, scale)
        cropH /= max(1.0, scale)

        // Center in source pixels. Vision normalized coords are
        // bottom-left origin, which matches CIImage's coordinate system.
        let cx = clamp(center.x, lo: 0, hi: 1) * srcExtent.width
        let cy = clamp(center.y, lo: 0, hi: 1) * srcExtent.height
        var x = cx - cropW / 2
        var y = cy - cropH / 2
        // Clamp to source bounds — never let the crop window step
        // outside the frame.
        x = clamp(x, lo: 0, hi: srcExtent.width - cropW)
        y = clamp(y, lo: 0, hi: srcExtent.height - cropH)
        let cropRect = CGRect(x: x, y: y, width: cropW, height: cropH)
        let cropped = image.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))

        // Scale to output.
        let sx = outputSize.width / cropW
        let sy = outputSize.height / cropH
        return cropped.transformed(
            by: CGAffineTransform(scaleX: sx, y: sy))
    }

    // MARK: - Transitions (Part 3D)

    private func applyTransition(blend: CinematicInstruction.TransitionBlend,
                                 a: CIImage,
                                 b: CIImage,
                                 outputSize: CGSize) -> CIImage {
        let t = CGFloat(blend.progress)
        let outBounds = CGRect(origin: .zero, size: outputSize)

        switch blend.kind {
        case .hardCut:
            return blend.progress < 0.5 ? a : b

        case .crossDissolve, .fadeFromBlack, .fadeToBlack:
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = a
            mix.targetImage = b
            mix.time = Float(blend.progress)
            return mix.outputImage?.cropped(to: outBounds) ?? a

        case .whipPan:
            // Slide A out left + motion-blur; B slides in from right.
            let dx = outputSize.width * t
            let aMoved = a.transformed(
                by: CGAffineTransform(translationX: -dx, y: 0))
            let motion = CIFilter.motionBlur()
            motion.inputImage = aMoved
            motion.radius = Float(40 * t)
            motion.angle = 0
            let aBlur = motion.outputImage ?? aMoved
            let bMoved = b.transformed(
                by: CGAffineTransform(translationX: outputSize.width * (1 - t),
                                      y: 0))
            // Composite B over A so the on-screen result is whichever
            // pixel lives in the output bounds.
            let combined = bMoved.composited(over: aBlur)
            return combined.cropped(to: outBounds)

        case .zoomPunch:
            // A scales up to ~1.25x while fading; B starts at 1.15x
            // and settles to 1.0x. Punchy on energetic boundaries.
            let aScale = 1.0 + 0.25 * t
            let aZoomed = scaleAroundCenter(a,
                                            scale: aScale,
                                            outputSize: outputSize)
            let bScale = 1.15 - 0.15 * t
            let bZoomed = scaleAroundCenter(b,
                                            scale: bScale,
                                            outputSize: outputSize)
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = aZoomed
            mix.targetImage = bZoomed
            mix.time = Float(t)
            return mix.outputImage?.cropped(to: outBounds) ?? bZoomed

        case .lightLeakWipe:
            // Additive warm flash that sweeps from left to right,
            // crossfading A→B underneath.
            let flashHalf = abs(t - 0.5) * 2 // 1 at edges, 0 at middle
            let flashIntensity = max(0, 1 - flashHalf)
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = a
            mix.targetImage = b
            mix.time = Float(t)
            let base = mix.outputImage?.cropped(to: outBounds) ?? a
            // Solid warm color image with intensity-modulated alpha.
            let warm = CIImage(color: CIColor(red: 1, green: 0.78,
                                              blue: 0.45,
                                              alpha: 0.7 * flashIntensity))
                .cropped(to: outBounds)
            return warm.composited(over: base).cropped(to: outBounds)
        }
    }

    private func scaleAroundCenter(_ image: CIImage,
                                   scale: CGFloat,
                                   outputSize: CGSize) -> CIImage {
        let cx = outputSize.width / 2
        let cy = outputSize.height / 2
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: cx, y: cy)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t)
    }

    private func clamp<T: Comparable>(_ v: T, lo: T, hi: T) -> T {
        min(max(v, lo), hi)
    }
}

// MARK: - Instruction

/// One AVVideoCompositionInstruction worth of render-time decisions.
/// Carries the EditPlan-derived crop keyframes for the source track A,
/// the active LUT for the entire reel, and (optionally) a transition
/// window into source track B.
final class CinematicInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    struct TransitionBlend {
        var kind: TransitionKind
        var progress: Double   // 0..1 across the transition window
    }

    let timeRange: CMTimeRange
    let trackAID: CMPersistentTrackID
    let trackBID: CMPersistentTrackID?
    let cropKeyframes: [CropKeyframe]
    let look: ColorLook
    /// Output time at which this instruction's segment begins. Used to
    /// translate compositionTime back into local "time since this clip
    /// started" for crop interpolation.
    let startSeconds: Double
    /// Transition spec, when this instruction sits across two clips.
    let transitionKind: TransitionKind?
    let transitionStart: Double?
    let transitionEnd: Double?

    init(timeRange: CMTimeRange,
         startSeconds: Double,
         trackAID: CMPersistentTrackID,
         trackBID: CMPersistentTrackID?,
         cropKeyframes: [CropKeyframe],
         look: ColorLook,
         transitionKind: TransitionKind?,
         transitionStart: Double?,
         transitionEnd: Double?) {
        self.timeRange = timeRange
        self.startSeconds = startSeconds
        self.trackAID = trackAID
        self.trackBID = trackBID
        self.cropKeyframes = cropKeyframes
        self.look = look
        self.transitionKind = transitionKind
        self.transitionStart = transitionStart
        self.transitionEnd = transitionEnd
        super.init()
    }

    // AVVideoCompositionInstructionProtocol requirements ----------------

    var enablePostProcessing: Bool { false }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? {
        var ids: [NSValue] = [NSNumber(value: trackAID)]
        if let b = trackBID { ids.append(NSNumber(value: b)) }
        return ids
    }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    // Interpolation ----------------------------------------------------

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

    /// Returns a copy with crop-irrelevant state suitable for rendering
    /// the *incoming* B-side track during a transition. The B track
    /// uses a centered/neutral crop because we have no per-frame
    /// keyframes for it inside this instruction (its own clip's
    /// instruction owns those — but for the transition span we just
    /// want a sane center-and-grade pass).
    func flipped() -> CinematicInstruction {
        CinematicInstruction(
            timeRange: timeRange,
            startSeconds: startSeconds,
            trackAID: trackBID ?? trackAID,
            trackBID: nil,
            cropKeyframes: [CropKeyframe(time: 0,
                                         center: CGPoint(x: 0.5, y: 0.5),
                                         scale: 1.0)],
            look: look,
            transitionKind: nil,
            transitionStart: nil,
            transitionEnd: nil)
    }
}
