//
//  LUTFactory.swift
//  PlayerCut/Composition
//
//  Procedural Core Image color cubes. We don't ship binary .cube files
//  because (a) they're large for the modest grades we want, (b) we'd
//  need a license claim per cube, and (c) we can construct visually
//  identical looks from a small set of channel transforms.
//
//  Each "look" is a 64-cube (262 144 floats) generated lazily once per
//  process and cached in memory. Float32 RGBA, in 0..1, matching what
//  CIFilter("CIColorCubeWithColorSpace") consumes.
//
//  Two looks are bundled:
//    Vivid   — punchy contrast, slightly warm; default for energetic / playful
//    Natural — gentle contrast, neutral; default for cinematic / chill
//

import CoreImage
import Foundation

enum LUTFactory {

    private static var cache: [ColorLook: Data] = [:]
    private static let dimension = 64
    private static let queue = DispatchQueue(label: "playercut.lut.cache")

    static func data(for look: ColorLook) -> Data {
        queue.sync {
            if let cached = cache[look] { return cached }
            let built = build(look: look)
            cache[look] = built
            return built
        }
    }

    static let cubeDimension: Int = dimension

    private static func build(look: ColorLook) -> Data {
        let n = dimension
        var floats: [Float] = []
        floats.reserveCapacity(n * n * n * 4)
        // OpenGL-style iteration order: B outer, G middle, R inner.
        for bi in 0..<n {
            let b = Float(bi) / Float(n - 1)
            for gi in 0..<n {
                let g = Float(gi) / Float(n - 1)
                for ri in 0..<n {
                    let r = Float(ri) / Float(n - 1)
                    let mapped = transform(r: r, g: g, b: b, look: look)
                    floats.append(mapped.r)
                    floats.append(mapped.g)
                    floats.append(mapped.b)
                    floats.append(1.0)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private struct RGB { var r: Float; var g: Float; var b: Float }

    /// Per-look channel mapping. Kept compact — every operation must
    /// have a clear visual purpose and stay subtle (the family of
    /// "Instagram filter" overgrading is exactly what parents will
    /// reject for kids' content).
    ///
    /// The result of `transform` is the LUT cube's mapped value. The
    /// MetalPetalCompositor blends this graded result with the
    /// corrected source at ~70 % opacity (NOT 100 %) so the look
    /// always reads "dialed in" rather than "filter dropped on top."
    /// // SOURCE: pixflow.net 2026-02-09 — pros apply creative LUTs
    /// // at 60-80 % opacity.
    private static func transform(r: Float, g: Float, b: Float,
                                  look: ColorLook) -> RGB {
        switch look {
        case .vivid:
            // S-curve contrast (sigmoid around 0.5), tiny warmth shift,
            // modest saturation boost.
            let cr = sigmoidContrast(r, strength: 1.18)
            let cg = sigmoidContrast(g, strength: 1.18)
            let cb = sigmoidContrast(b, strength: 1.18)
            let warm = warmth(r: cr, g: cg, b: cb, k: 0.04)
            let sat = saturate(r: warm.r, g: warm.g, b: warm.b, k: 1.12)
            return RGB(r: clamp(sat.r), g: clamp(sat.g), b: clamp(sat.b))
        case .natural:
            // Gentle contrast, slight green damp, mild saturation tweak.
            let cr = sigmoidContrast(r, strength: 1.07)
            let cg = sigmoidContrast(g, strength: 1.07) * 0.985
            let cb = sigmoidContrast(b, strength: 1.07)
            let sat = saturate(r: cr, g: cg, b: cb, k: 1.04)
            return RGB(r: clamp(sat.r), g: clamp(sat.g), b: clamp(sat.b))
        case .stadium:
            // Teal-orange action grade. Pulls midtone blues toward
            // teal (boost green slightly, dampen blue), warms highlights
            // (lift red+green, dampen blue), and lifts shadows so dark
            // jerseys still read on small screens.
            // // SOURCE: localeyesit.com 2026-01-19 — sports
            // // broadcast convention.
            let cr = sigmoidContrast(r, strength: 1.16)
            let cg = sigmoidContrast(g, strength: 1.16)
            let cb = sigmoidContrast(b, strength: 1.16)
            // Shadow lift (gamma 0.92 in shadows).
            let lift = shadowLift(r: cr, g: cg, b: cb, amount: 0.08)
            // Teal shadow → orange highlight split-tone.
            let luma = 0.2126 * lift.r + 0.7152 * lift.g + 0.0722 * lift.b
            // shadowWeight peaks at low luma; highlightWeight at high.
            let shadowW = max(0, 1 - luma * 1.6)
            let highlightW = max(0, (luma - 0.45) * 1.4)
            // Teal: +green +blue
            let tealG = lift.g + 0.05 * shadowW
            let tealB = lift.b + 0.08 * shadowW
            // Orange: +red +green
            let orR = tealG > 0 ? lift.r + 0.10 * highlightW : lift.r
            let orG = tealG + 0.04 * highlightW
            let sat = saturate(r: orR, g: orG, b: tealB, k: 1.18)
            return RGB(r: clamp(sat.r), g: clamp(sat.g), b: clamp(sat.b))
        case .warm:
            // Gentle cinematic — subtle warmth (+R, -B), slight
            // shadow lift, compressed highlights to protect skin from
            // blowing out under bright sun.
            let cr = sigmoidContrast(r, strength: 1.10)
            let cg = sigmoidContrast(g, strength: 1.10)
            let cb = sigmoidContrast(b, strength: 1.10)
            let lift = shadowLift(r: cr, g: cg, b: cb, amount: 0.06)
            let warm = warmth(r: lift.r, g: lift.g, b: lift.b, k: 0.06)
            // Soft highlight roll-off — pull the top 20% of luminance
            // back toward 0.92 to avoid clipping.
            let luma = 0.2126 * warm.r + 0.7152 * warm.g + 0.0722 * warm.b
            let topW = max(0, (luma - 0.8) * 5)  // 0..1 over [0.8, 1.0]
            let rolloff: Float = 0.08 * topW
            let outR = warm.r - rolloff
            let outG = warm.g - rolloff
            let outB = warm.b - rolloff
            return RGB(r: clamp(outR), g: clamp(outG), b: clamp(outB))
        }
    }

    /// Gentle shadow lift via gamma in the lower luma band. `amount`
    /// is the additive boost at black; falls off linearly to 0 by
    /// luma = 0.5.
    private static func shadowLift(r: Float, g: Float, b: Float,
                                   amount: Float) -> RGB {
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let w = max(0, 1 - lum * 2)  // weight: 1 at black, 0 at midgrey
        let lift = amount * w
        return RGB(r: r + lift, g: g + lift, b: b + lift)
    }

    private static func sigmoidContrast(_ x: Float, strength k: Float) -> Float {
        // Symmetric sigmoid centered at 0.5; tuned so x ∈ [0,1] maps
        // roughly to [0,1] without clipping at the toes.
        let centered = x - 0.5
        let stretched = tanh(centered * k) / tanh(k * 0.5)
        return 0.5 + 0.5 * stretched
    }

    private static func warmth(r: Float, g: Float, b: Float, k: Float) -> RGB {
        RGB(r: r + k * 0.5, g: g, b: b - k * 0.5)
    }

    private static func saturate(r: Float, g: Float, b: Float, k: Float) -> RGB {
        // Luminance-preserving saturation scale.
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return RGB(r: lum + (r - lum) * k,
                   g: lum + (g - lum) * k,
                   b: lum + (b - lum) * k)
    }

    private static func clamp(_ v: Float) -> Float {
        min(1, max(0, v))
    }
}
