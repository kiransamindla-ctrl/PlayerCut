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
    ///
    /// Stabilization choice .cinematic is REQUESTED for every tier
    /// from A14 up; the actual application checks the connection
    /// (`isVideoStabilizationModeSupported(.cinematic)`) and falls
    /// back to .standard when the chosen format doesn't support it.
    /// Cinematic stabilization is what gives Trace/Veo footage its
    /// smooth-pan look. // SOURCE: traceup.com trace-vs-veo
    /// 2025-02-14 — Trace clarity attributed to "stability".
    static func idealRecipe(for tier: SoCTier) -> CaptureRecipe {
        switch effectiveTier(tier) {
        case .a17, .a18plus:
            return CaptureRecipe(resolution: .uhd4k, fps: 60,
                                 codec: .hevc, stabilization: .cinematic)
        case .a14, .a15, .a16:
            return CaptureRecipe(resolution: .uhd4k, fps: 60,
                                 codec: .hevc, stabilization: .cinematic)
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
    /// "Supports" means:
    ///   1. Format dimensions match (must not exceed the cap).
    ///   2. videoSupportedFrameRateRanges contains the target fps —
    ///      RANGE-based, not exact. AVFoundation reports ranges like
    ///      (min: 1, max: 60), so a "4K60" format is just a 4K format
    ///      whose range *contains* 60. Apple Developer Forum threads
    ///      document devices where exact-rate matching returns no
    ///      results even on a camera that records 4K60 cleanly.
    ///   3. (When requireHEVC) media subtype is hvc1 OR hev1.
    ///      // SOURCE: Apple TN3115; AV Foundation accepts both
    ///      // four-char codes for HEVC.
    static func bestSupportedFormat(
        for device: AVCaptureDevice,
        maxDimensions: CMVideoDimensions,
        targetFPS: Int,
        requireHEVC: Bool
    ) -> AVCaptureDevice.Format? {
        var bestMatch: AVCaptureDevice.Format?
        var bestArea: Int32 = 0

        // 'hvc1' = 0x68766331; 'hev1' = 0x68657631. Either FourCC is HEVC.
        let hvc1Code: FourCharCode = 0x68766331
        let hev1Code: FourCharCode = 0x68657631

        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Must not exceed the cap; we want the largest area that fits.
            guard d.width <= maxDimensions.width,
                  d.height <= maxDimensions.height else { continue }

            // Range CONTAINS targetFPS (not exact match — see above).
            let fpsOK = format.videoSupportedFrameRateRanges.contains { range in
                Double(targetFPS) >= range.minFrameRate
                    && Double(targetFPS) <= range.maxFrameRate
            }
            guard fpsOK else { continue }

            if requireHEVC {
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                guard subtype == hvc1Code || subtype == hev1Code else { continue }
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
    /// given device. **HEVC-strict** — the caller's recordability
    /// ladder (GameCaptureController.applyRecipeOnSessionQueue) is the
    /// place where resolution+fps step-down happens. This function only
    /// answers "does this exact (res, fps) exist as an HEVC format on
    /// this device?". HEVC is ~2× more bandwidth-efficient than H.264
    /// at equal quality (// SOURCE: hevcut.com iphone-video-recording-
    /// settings-optimization, accessed 2026-05-17), so we prefer HEVC
    /// at a LOWER rung over H.264 at a HIGHER rung.
    ///
    /// Returns (nil, recipe) when no HEVC format matches. The outer
    /// ladder then steps down to the next rung. If the entire ladder
    /// finds no HEVC format, only then do we fall through to the
    /// H.264 escape hatch via `resolveFormatAllowingH264`.
    static func resolveFormat(_ recipe: CaptureRecipe,
                              on device: AVCaptureDevice)
        -> (format: AVCaptureDevice.Format?, recipe: CaptureRecipe) {
        if let f = bestSupportedFormat(for: device,
                                       maxDimensions: recipe.resolution.dimensions,
                                       targetFPS: recipe.fps,
                                       requireHEVC: true) {
            return (f, recipe)
        }
        return (nil, recipe)
    }

    /// Escape hatch — called by the ladder ONLY after the HEVC-strict
    /// ladder has exhausted every rung. Returns the highest H.264
    /// format that matches the recipe's resolution + fps, with the
    /// recipe's codec field flipped to .h264 so the rest of the
    /// pipeline knows.
    static func resolveFormatAllowingH264(_ recipe: CaptureRecipe,
                                          on device: AVCaptureDevice)
        -> (format: AVCaptureDevice.Format?, recipe: CaptureRecipe) {
        var attempt = recipe
        if let f = bestSupportedFormat(for: device,
                                       maxDimensions: recipe.resolution.dimensions,
                                       targetFPS: recipe.fps,
                                       requireHEVC: false) {
            attempt.codec = .h264
            log.warning("HEVC ladder exhausted — falling back to H.264 \(recipe.resolution.rawValue)@\(recipe.fps)")
            return (f, attempt)
        }
        return (nil, recipe)
    }

    // MARK: - Diagnostic format dump

    /// One-time dump of every AVCaptureDevice.Format the device
    /// enumerates. Called once at configure() before the ladder runs.
    /// Goal: ground-truth what's actually on this camera so the
    /// matcher can be fixed against real data, not assumptions.
    ///
    /// Each format gets ONE log line under category "FormatDump" with
    /// the fields the user asked for in the diagnostic spec:
    ///   - dimensions (WxH from CMVideoFormatDescriptionGetDimensions)
    ///   - media subtype four-CC (this is the PIXEL FORMAT, e.g.
    ///     '420v' / '420f', NOT the encode codec — important: the
    ///     current matcher checks this against 'hvc1' which is wrong;
    ///     HEVC vs H.264 is decided at encode time, not by the
    ///     capture format's pixel layout)
    ///   - videoSupportedFrameRateRanges (min...max for each range)
    ///   - supportedColorSpaces (sRGB / P3_D65 / HLG_BT2020 / appleLog)
    ///   - isVideoHDRSupported
    ///   - isMultiCamSupported (Apple often hides 4K formats behind
    ///     this flag — if it's true, the format is a multi-cam format
    ///     that may not be usable for our single-cam recording)
    ///   - supportedMaxPhotoDimensions count (photo-capable formats
    ///     have non-empty arrays; video-only formats are empty)
    ///
    /// Read this in Xcode console (filter: subsystem com.playercut.app,
    /// category FormatDump) or via idevicesyslog | grep FormatDump.
    static func dumpFormats(for device: AVCaptureDevice,
                            label: String) {
        let log = Logger(subsystem: "com.playercut.app",
                         category: "FormatDump")
        log.info("─── Format dump for \(label, privacy: .public) (\(device.formats.count) formats) ───")
        for (i, format) in device.formats.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(
                format.formatDescription)
            let fourCC = fourCCString(subtype)
            let rangesStr = format.videoSupportedFrameRateRanges
                .map { "\(Int($0.minFrameRate))...\(Int($0.maxFrameRate))" }
                .joined(separator: ",")
            let colorSpaces = format.supportedColorSpaces
                .map(colorSpaceLabel(_:))
                .joined(separator: "/")
            let photoDims = format.supportedMaxPhotoDimensions.count
            log.info("[\(i)] \(dims.width)x\(dims.height) subtype=\(fourCC, privacy: .public) fps=\(rangesStr, privacy: .public) colors=\(colorSpaces, privacy: .public) HDR=\(format.isVideoHDRSupported) multicam=\(format.isMultiCamSupported) photoDims=\(photoDims)")
        }
        log.info("─── end format dump ───")
    }

    /// Converts an OSType (FourCharCode) into its 4-character string
    /// representation. Returns "????" for non-printable codes.
    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8)  & 0xFF),
            UInt8( code        & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return String(format: "0x%08x", code)
        }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// Friendly label for AVCaptureColorSpace raw values.
    private static func colorSpaceLabel(_ cs: AVCaptureColorSpace) -> String {
        switch cs {
        case .sRGB:       return "sRGB"
        case .P3_D65:     return "P3"
        case .HLG_BT2020: return "HLG"
        case .appleLog:   return "AppleLog"
        @unknown default: return "cs(\(cs.rawValue))"
        }
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
