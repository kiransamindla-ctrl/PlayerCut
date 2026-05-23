//
//  DeviceCapabilities.swift
//  PlayerCut/Capture
//
//  Minimal SoC-tier identification. Kept after the custom
//  AVCaptureSession was retired because non-capture code paths
//  still need to know the device's chip family for compose-time
//  ETA + diagnostics — e.g. ETAEstimator persists per-tier per-stage
//  EMA timings, and DiagnosticsStore records `capture_soc_tier`.
//
//  The format/recipe/downgrade ladder this file used to host was
//  deleted with the custom capture pipeline; recording is now done
//  by UIImagePickerController (the system Camera UI) which owns
//  format selection, codec choice, color space, and stabilization
//  identically to the stock Camera app.
//

import Foundation
import os.log

/// Apple-silicon generations that matter for per-device compose-time
/// performance gating. New chips fall into `a18plus`; anything older
/// than iPhone 11 is below the iOS 17 deployment floor and won't
/// reach this code.
enum SoCTier: String, Codable, CaseIterable {
    case a13      // iPhone 11 family + SE 2
    case a14      // iPhone 12 family
    case a15      // iPhone 13 / 14 / 14 Plus + SE 3
    case a16      // iPhone 14 Pro family + 15 / 15 Plus
    case a17      // iPhone 15 Pro family (A17 Pro)
    case a18plus  // iPhone 16+, A18 / A18 Pro, anything newer
    case unknown  // simulator / pre-release identifiers — treated as a17
}

/// Capture recipe placeholder retained for binary-compat with games
/// recorded under the previous custom-capture flow (their persisted
/// GameSession JSON references this type). New games captured via
/// the system Camera leave `GameSession.captureRecipe` as nil — we
/// don't know what the system Camera picked.
///
/// Field types match the legacy JSON shape on disk; nothing in the
/// runtime drives AVFoundation from this anymore.
struct CaptureRecipe: Codable, Equatable {

    enum Resolution: String, Codable {
        case uhd4k = "4k"
        case fhd1080 = "1080p"
    }

    enum Stabilization: String, Codable {
        case off
        case standard
        case cinematic
    }

    var resolution: Resolution
    var fps: Int
    var codec: String          // "hvc1" / "avc1" — opaque now
    var stabilization: Stabilization

    var providesRealSlowMoSource: Bool { fps >= 60 }
}

/// Static facts about the device. Sole consumer post-pivot is
/// ETAEstimator (per-tier per-stage EMA timings) and DiagnosticsStore
/// (capture_soc_tier enum distribution).
enum DeviceCapabilities {

    static func currentTier() -> SoCTier {
        tier(forMachineIdentifier: machineIdentifier())
    }

    static func tier(forMachineIdentifier id: String) -> SoCTier {
        switch id {
        case "iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8":
            return .a13
        case "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4":
            return .a14
        case "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
             "iPhone14,6", "iPhone14,7", "iPhone14,8":
            return .a15
        case "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5":
            return .a16
        case "iPhone16,1", "iPhone16,2":
            return .a17
        case _ where id.hasPrefix("iPhone17,"),
             _ where id.hasPrefix("iPhone18,"),
             _ where id.hasPrefix("iPhone19,"),
             _ where id.hasPrefix("iPhone2"):
            return .a18plus
        default:
            return .unknown
        }
    }

    static func effectiveTier(_ tier: SoCTier) -> SoCTier {
        tier == .unknown ? .a17 : tier
    }

    static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        var id = ""
        for child in mirror.children {
            if let value = child.value as? Int8, value != 0 {
                id.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return id
    }
}

/// Loudness sample written to the per-game audio-loudness sidecar.
/// Pre-pivot this lived inside GameCaptureController; relocated here
/// because Stage 1's decoder still references the type. New games
/// captured via UIImagePickerController write an empty array (no
/// loudness analysis runs); Stage 1's never-reject contract handles
/// the zero-peak case.
struct LoudnessSample: Codable {
    let t: Double      // seconds since recording start
    let rms: Float     // 0..1
}
