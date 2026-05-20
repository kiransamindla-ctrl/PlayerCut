//
//  DeviceCapabilities.swift
//  PlayerCut/Capture
//
//  Per-device capture recipe. Decides resolution + fps + codec +
//  stabilization based on the SoC the user is holding right now, then
//  asks AVCaptureDevice for the closest activeFormat that actually
//  supports those numbers. If the ideal recipe isn't available we step
//  down — never up. All thermal/battery downgrade decisions are pure
//  functions over the live ProcessInfo / UIDevice state so they're
//  trivially testable.
//
//  Source for tier mapping: Apple device identifiers from
//  https://support.apple.com/en-us/108044 (iPhone), cross-referenced
//  with the chip-family announcements on apple.com/newsroom (accessed
//  2026-05-17). New identifiers default to the highest tier (a18plus)
//  because the deployment-target floor is iPhone 13 (A15).
//

import AVFoundation
import Foundation
import os.log

/// Apple-silicon generations that matter to sustained capture. New
/// chips fall into `a18plus`; anything older than iPhone 11 is below
/// the iOS 17 deployment floor and won't reach this code.
enum SoCTier: String, Codable, CaseIterable {
    case a13      // iPhone 11 family + SE 2
    case a14      // iPhone 12 family
    case a15      // iPhone 13 / 14 / 14 Plus + SE 3
    case a16      // iPhone 14 Pro family + 15 / 15 Plus
    case a17      // iPhone 15 Pro family (A17 Pro)
    case a18plus  // iPhone 16+, A18 / A18 Pro, anything newer
    case unknown  // simulator / pre-release identifiers — treated as a17
}

/// What the capture session should actually do on this device. Pure
/// data; no AVFoundation handles inside so it survives encoding to a
/// GameSession.
struct CaptureRecipe: Codable, Equatable {

    enum Resolution: String, Codable {
        case uhd4k = "4k"
        case fhd1080 = "1080p"

        var dimensions: CMVideoDimensions {
            switch self {
            case .uhd4k:    return CMVideoDimensions(width: 3840, height: 2160)
            case .fhd1080:  return CMVideoDimensions(width: 1920, height: 1080)
            }
        }
    }

    enum Stabilization: String, Codable {
        case off
        case standard
        case cinematic
    }

    var resolution: Resolution
    var fps: Int
    /// Always HEVC under our codebase rules; recorded explicitly so a
    /// future migration can carry the choice forward and so logging /
    /// diagnostics can see when we had to fall back to H.264.
    var codec: AVVideoCodecType
    var stabilization: Stabilization
    /// HDR is always disabled — washes out kids' jerseys, breaks
    /// sharing to non-Apple platforms.
    /// SOURCE: shopmoment.com/journal/best-iphone-camera-settings
    /// (accessed 2026-01-22).
    var hdrEnabled: Bool { false }

    /// True when this recipe gives the composer real-60fps source for
    /// stretched-time slow-mo (vs. having to frame-blend or skip the
    /// ramp). The composer reads this off GameSession.
    var providesRealSlowMoSource: Bool { fps >= 60 }

    private enum CodingKeys: String, CodingKey {
        case resolution, fps, codec, stabilization
    }

    init(resolution: Resolution,
         fps: Int,
         codec: AVVideoCodecType = .hevc,
         stabilization: Stabilization = .standard) {
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.stabilization = stabilization
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decode(Resolution.self, forKey: .resolution)
        fps = try c.decode(Int.self, forKey: .fps)
        let codecRaw = try c.decode(String.self, forKey: .codec)
        codec = AVVideoCodecType(rawValue: codecRaw)
        stabilization = try c.decode(Stabilization.self, forKey: .stabilization)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(fps, forKey: .fps)
        try c.encode(codec.rawValue, forKey: .codec)
        try c.encode(stabilization, forKey: .stabilization)
    }
}

/// Static facts about the device + helpers for picking + verifying a
/// recipe. Not an actor — every read is a snapshot. Capture controllers
/// call this from the main actor.
enum DeviceCapabilities {

    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "Capabilities")

    // MARK: - Tier mapping

    /// SoC tier the current device belongs to. Uses `utsname.machine`,
    /// which is the only on-device identifier Apple guarantees we can
    /// read without entitlements.
    /// SOURCE: device identifier list cross-referenced with
    /// https://support.apple.com/en-us/108044 (iPhone) — accessed
    /// 2026-05-17.
    static func currentTier() -> SoCTier {
        tier(forMachineIdentifier: machineIdentifier())
    }

    static func tier(forMachineIdentifier id: String) -> SoCTier {
        switch id {
        // A13: iPhone 11 family + SE 2nd gen
        case "iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8":
            return .a13
        // A14: iPhone 12 family
        case "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4":
            return .a14
        // A15: iPhone 13 family, iPhone 14 / 14 Plus, SE 3rd gen
        case "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
             "iPhone14,6", "iPhone14,7", "iPhone14,8":
            return .a15
        // A16: iPhone 14 Pro / Pro Max + iPhone 15 / 15 Plus
        case "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5":
            return .a16
        // A17 Pro: iPhone 15 Pro / Pro Max
        case "iPhone16,1", "iPhone16,2":
            return .a17
        // A18 / A18 Pro: iPhone 16 family and everything newer
        case _ where id.hasPrefix("iPhone17,"),
             _ where id.hasPrefix("iPhone18,"),
             _ where id.hasPrefix("iPhone19,"),
             _ where id.hasPrefix("iPhone2"):
            return .a18plus
        // Simulator / pre-release identifiers fall back to a17 behavior.
        // Spec calls this "unknown/newer to a17 tier".
        default:
            return .unknown
        }
    }

    /// The intent of `unknown` is "newer hardware we don't yet recognize" —
    /// the spec says treat it as a17. Recipe selection collapses unknown
    /// into a17 here so call sites don't have to.
    static func effectiveTier(_ tier: SoCTier) -> SoCTier {
        tier == .unknown ? .a17 : tier
    }

    // MARK: - Recipe selection

    /// Ideal recipe purely from tier — no thermal / battery awareness.
    /// Use `liveRecipe(...)` for the version that bakes in current
    /// device state.
    static func idealRecipe(for tier: SoCTier) -> CaptureRecipe {
        switch effectiveTier(tier) {
        case .a17, .a18plus:
            return CaptureRecipe(resolution: .uhd4k, fps: 60,
                                 codec: .hevc, stabilization: .cinematic)
        case .a14, .a15, .a16:
            return CaptureRecipe(resolution: .uhd4k, fps: 60,
                                 codec: .hevc, stabilization: .standard)
        case .a13:
            return CaptureRecipe(resolution: .fhd1080, fps: 60,
                                 codec: .hevc, stabilization: .standard)
        case .unknown:
            // collapsed above, but keep the case exhaustive
            return CaptureRecipe(resolution: .uhd4k, fps: 60,
                                 codec: .hevc, stabilization: .cinematic)
        }
    }

    /// Recipe taking the live thermal + battery + low-power state into
    /// account. Mirrors the ladder in `downgrade(_:for:battery:)` so
    /// new sessions start at the same level a degraded session would
    /// reconfigure to.
    static func liveRecipe(for tier: SoCTier,
                           thermal: ProcessInfo.ThermalState,
                           batteryLevel: Float,
                           lowPower: Bool) -> CaptureRecipe {
        let ideal = idealRecipe(for: tier)
        return downgrade(ideal,
                         for: thermal,
                         batteryLevel: batteryLevel,
                         lowPower: lowPower)
    }

    /// Applies the spec's thermal/battery ladder to an existing recipe.
    /// Returns the same recipe if no downgrade applies.
    static func downgrade(_ recipe: CaptureRecipe,
                          for thermal: ProcessInfo.ThermalState,
                          batteryLevel: Float,
                          lowPower: Bool) -> CaptureRecipe {
        // batteryLevel == -1 → battery monitoring not enabled
        // (simulator / pre-monitoring); treat as "fine".
        let knownBattery = batteryLevel >= 0
        let critical = thermal == .critical
            || (knownBattery && batteryLevel < 0.10)
        let serious = thermal == .serious
            || (knownBattery && batteryLevel < 0.20)
            || lowPower

        var out = recipe
        if critical {
            // critical: 1080p30, .standard stabilization
            out.resolution = .fhd1080
            out.fps = 30
            if out.stabilization == .cinematic {
                out.stabilization = .standard
            }
        } else if serious {
            // serious: 4K → 1080p, keep 60fps
            if out.resolution == .uhd4k {
                out.resolution = .fhd1080
            }
            if out.stabilization == .cinematic {
                out.stabilization = .standard
            }
        }
        return out
    }

    // MARK: - Format lookup (does the device actually support this?)

    /// Best supported AVCaptureDevice.Format for the requested
    /// dimensions + fps + codec. Returns nil if nothing comes close —
    /// callers step down their recipe and retry.
    ///
    /// "Supports" here means: format dimensions match, the format has
    /// a videoSupportedFrameRateRange covering `targetFPS`, and (when
    /// requireHEVC) the format's mediaSubType is HEVC.
    static func bestSupportedFormat(
        for device: AVCaptureDevice,
        maxDimensions: CMVideoDimensions,
        targetFPS: Int,
        requireHEVC: Bool
    ) -> AVCaptureDevice.Format? {
        var bestMatch: AVCaptureDevice.Format?
        var bestArea: Int32 = 0

        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Must not exceed the cap; we want the largest area that fits.
            guard d.width <= maxDimensions.width,
                  d.height <= maxDimensions.height else { continue }

            // fps support
            let fpsOK = format.videoSupportedFrameRateRanges.contains { range in
                Double(targetFPS) >= range.minFrameRate
                    && Double(targetFPS) <= range.maxFrameRate
            }
            guard fpsOK else { continue }

            if requireHEVC {
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                // 'hvc1' is HEVC; treat anything else as non-HEVC.
                let hevcCode: FourCharCode = 0x68766331  // 'hvc1'
                guard subtype == hevcCode else { continue }
            }

            let area = d.width * d.height
            if area > bestArea {
                bestArea = area
                bestMatch = format
            }
        }
        return bestMatch
    }

    /// Resolves a recipe to a concrete AVCaptureDevice.Format on the
    /// given device, stepping down as needed:
    ///   1. Ideal recipe at HEVC.
    ///   2. Same recipe but H.264 acceptable (logs the codec fallback).
    ///   3. 30fps at the same resolution.
    ///   4. 1080p30 HEVC.
    /// If nothing matches we return (nil, original recipe) and the
    /// caller surfaces a captureFailed error.
    static func resolveFormat(_ recipe: CaptureRecipe,
                              on device: AVCaptureDevice)
        -> (format: AVCaptureDevice.Format?, recipe: CaptureRecipe) {

        var attempt = recipe

        // 1. Ideal HEVC.
        if let f = bestSupportedFormat(for: device,
                                       maxDimensions: attempt.resolution.dimensions,
                                       targetFPS: attempt.fps,
                                       requireHEVC: true) {
            return (f, attempt)
        }

        // 2. Same resolution + fps, allow H.264.
        if let f = bestSupportedFormat(for: device,
                                       maxDimensions: attempt.resolution.dimensions,
                                       targetFPS: attempt.fps,
                                       requireHEVC: false) {
            log.warning("Recipe \(attempt.resolution.rawValue)@\(attempt.fps): HEVC unavailable, dropping to H.264")
            attempt.codec = .h264
            return (f, attempt)
        }

        // 3. Drop fps to 30.
        if attempt.fps != 30 {
            attempt.fps = 30
            if let f = bestSupportedFormat(for: device,
                                           maxDimensions: attempt.resolution.dimensions,
                                           targetFPS: 30,
                                           requireHEVC: true) {
                log.warning("Recipe stepped down: \(recipe.fps)fps → 30fps")
                return (f, attempt)
            }
        }

        // 4. Final fallback: 1080p30 HEVC.
        attempt = CaptureRecipe(resolution: .fhd1080, fps: 30,
                                codec: .hevc,
                                stabilization: recipe.stabilization)
        if let f = bestSupportedFormat(for: device,
                                       maxDimensions: attempt.resolution.dimensions,
                                       targetFPS: 30,
                                       requireHEVC: true) {
            log.warning("Recipe stepped down to floor: 1080p30 HEVC")
            return (f, attempt)
        }
        return (nil, recipe)
    }

    // MARK: - Machine identifier

    /// `utsname.machine` value. Public so tests can override the input
    /// to `tier(forMachineIdentifier:)`.
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
