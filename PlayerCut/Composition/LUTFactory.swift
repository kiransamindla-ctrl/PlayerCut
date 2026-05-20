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
        }
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
