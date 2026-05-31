//
//  EditPlan.swift
//  PlayerCut/Composition
//
//  Edit-time decisions, separated from render-time mechanics. The
//  HighlightRanker produces a ReelPlan (which clips); the
//  EditPlanBuilder enriches that into an EditPlan (how to render every
//  clip — crop keyframes, speed curves, transitions, beat grid, titles).
//  The ReelComposer is now a *renderer* that consumes an EditPlan with
//  no taste of its own; all "what should this look like" decisions live
//  here so we can A/B styles and (later, Phase 4) hand them to a manual
//  editor without touching render code.
//

import CoreGraphics
import Foundation

// MARK: - Styles

/// Top-level look-and-feel preset. Maps cleanly from MusicVibe so the
/// audio mood and visual mood always agree by default.
enum EditStyle: String, Codable, CaseIterable {
    /// Fast cuts, zoom-punch transitions, vivid grade. Default for
    /// energetic music vibes.
    case energetic
    /// Longer holds, dissolves, gentler speed ramps, natural grade.
    /// Default for cinematic vibes.
    case cinematic
    /// Bouncy pacing, light-leak wipes, vivid grade. Default for
    /// playful vibes.
    case playful
    /// Restrained: dissolves only, no speed ramps, natural grade.
    /// Default for chill vibes (also the safe choice on weak hardware).
    case chill

    static func defaultFor(musicVibe: MusicVibe) -> EditStyle {
        switch musicVibe {
        case .energetic: return .energetic
        case .cinematic: return .cinematic
        case .playful:   return .playful
        case .chill:     return .chill
        }
    }

    /// Whether this style permits speed-ramp slow-mo at action apexes.
    var allowsSpeedRamps: Bool {
        switch self {
        case .energetic, .cinematic, .playful: return true
        case .chill: return false
        }
    }

    /// LUT per style, per the Section 3 spec:
    ///   - Energetic → Stadium (teal-orange action grade)
    ///   - Cinematic → Warm (gentle warmth, lifted shadows)
    ///   - Playful → Vivid (punchy contrast + saturation)
    ///   - Chill → Natural (neutral, gentle)
    /// // SOURCE: localeyesit.com 2026-01-19 (teal/orange = sports);
    /// // pixflow.net 2026-02-09 (creative LUT at 60-80% intensity —
    /// // applied in MetalPetalCompositor via blend with corrected
    /// // source, not at full strength).
    var lookUpTable: ColorLook {
        switch self {
        case .energetic: return .stadium
        case .cinematic: return .warm
        case .playful:   return .vivid
        case .chill:     return .natural
        }
    }

    /// Default transitions emitted by EditPlanBuilder for "medium energy"
    /// boundaries. High-energy boundaries always escalate to a zoom-punch
    /// or whip; opening always fades from black.
    var defaultBoundaryTransition: TransitionKind {
        switch self {
        case .energetic: return .zoomPunch
        case .playful:   return .lightLeakWipe
        case .cinematic, .chill: return .crossDissolve
        }
    }
}

/// Bundled cinematic look. Backed by a procedurally-generated CIColorCube
/// in LUTFactory so we don't have to ship a binary .cube file.
///
/// New in the quality-build (Section 3):
///   - stadium: teal-orange action grade (push blues toward teal,
///     boost orange in skin/highlights). The default for energetic
///     sports content. // SOURCE: localeyesit.com 2026-01-19 — teal/
///     orange is the broadcast palette for sports.
///   - warm: subtle warmth + lifted shadows, slightly compressed
///     highlights. The cinematic look without going full Hollywood.
enum ColorLook: String, Codable {
    case vivid
    case natural
    case stadium    // teal-orange sports
    case warm       // gentle cinematic
    case punchy     // high-contrast / high-sat — for fast-cut / attitude templates
    case soft       // lifted blacks, desaturated cyan-pink — aesthetic-slow / dreamy
}

// MARK: - Plan + child types

struct EditPlan {
    /// Cold-open clip: a 1.2–1.8s slice of the single highest-energy
    /// moment in the reel, placed first to hook the viewer.
    /// nil when the source has no qualifying high-energy moment (e.g.
    /// Tier 3 montage), in which case the first body clip leads.
    var coldOpen: ClipPlan?
    /// Animated title card spec; rendered between cold open and body.
    /// nil disables the card (e.g. on weakest devices).
    var titleCard: TitleCardSpec?
    /// Animated lower-third spec — slides in on the first body clip.
    var lowerThird: LowerThirdSpec?
    /// Body clips, in render order.
    var body: [ClipPlan]
    /// Closing card spec.
    var closingCard: ClosingCardSpec?

    /// Beat grid in seconds, monotonically increasing, starting at 0.
    /// Boundaries between body clips snap to the nearest beat in this
    /// grid; transitions also key off these times.
    var beatGrid: [Double]
    /// Resolved overall style.
    var style: EditStyle
    /// Final output spec passed through to the renderer.
    var output: OutputSpec
    /// Music URL when one is bundled/picked; nil → silent reel.
    var musicURL: URL?
    /// What ranker tier produced the underlying clip selection.
    /// Useful for diagnostics + debug logging.
    var sourceTier: RankerTier

    /// Sum of every renderable segment's wall-clock duration.
    var totalDuration: Double {
        var t: Double = 0
        if let coldOpen { t += coldOpen.renderedDuration }
        if titleCard != nil  { t += TitleCardSpec.duration }
        if closingCard != nil { t += ClosingCardSpec.duration }
        t += body.reduce(0) { $0 + $1.renderedDuration }
        return t
    }
}

struct OutputSpec {
    var size: CGSize
    var fps: Int
    /// Use HEVC where AVFoundation supports it; falls back to H.264 on
    /// older devices via export preset compatibility check.
    var preferHEVC: Bool = true
}

/// Pacing tier (Section 2). The ranker doesn't know tiers — they're
/// assigned by EditPlanBuilder based on score percentile so the top
/// play gets the long hold + slow-mo + apex freeze, the rest stay tight.
enum PacingTier: String, Codable {
    /// Top 1-2 plays. Long hold (~4-6s), slow-mo at apex, 0.3s freeze.
    case hero
    /// Next ~30%. Standard (~3-4s, normal speed).
    case feature
    /// Remaining body. Tight hard cuts on the beat (~2-3s).
    case filler
}

/// One renderable segment of source video, with all decisions baked in.
struct ClipPlan: Identifiable {
    let id: UUID
    /// Source video time range, in seconds.
    var sourceStart: Double
    var sourceEnd: Double
    /// Auto-reframe keyframes: normalized (0..1) source-frame centers,
    /// already smoothed by critical damping in the builder. Sampled at
    /// `cropKeyframeHz`. The renderer interpolates between keyframes
    /// linearly during composition.
    var cropKeyframes: [CropKeyframe]
    /// Per-segment speed factor curve. Linear factor=1 → no ramp.
    var speedCurve: SpeedCurve
    /// How the next boundary (this → next clip) blends.
    var outgoingTransition: TransitionKind
    /// 0..1 energy score (derived from composite + audio + action).
    /// Drives transition choice and ramp aggression.
    var energy: Float
    /// Section 2 pacing tier. Defaults to .feature (no special handling).
    var pacingTier: PacingTier = .feature
    /// Extra rendered seconds tacked on by holding the last frame —
    /// hero "apex freeze." 0 = no freeze. ReelComposer.insertClip honors
    /// it by inserting one last source frame scaled to this duration.
    var freezeFrameSeconds: Double = 0

    /// Source duration before any speed mapping.
    var sourceDuration: Double { sourceEnd - sourceStart }

    /// Rendered (output) duration after the speed curve has been applied
    /// AND the apex freeze (if any). Speed factor < 1.0 stretches time;
    /// freeze adds a held final frame on top.
    var renderedDuration: Double {
        speedCurve.renderedDuration(forSource: sourceDuration)
            + freezeFrameSeconds
    }
}

struct CropKeyframe {
    /// Seconds from the start of the clip.
    var time: Double
    /// Normalized source-frame center (0..1, Vision-coords origin
    /// bottom-left). Renderer flips for UIKit.
    var center: CGPoint
    /// Crop scale: 1.0 = the maximum-fit crop window for the output
    /// aspect; 1.0 is default. Values > 1.0 zoom in further (e.g. for
    /// zoom-punch transitions).
    var scale: CGFloat
}

// MARK: - Speed curves

/// Piecewise time mapping. The renderer realizes this by inserting
/// per-segment scaled time-ranges into the AVMutableComposition.
struct SpeedCurve {
    struct Segment {
        /// Fraction of the source clip [0..1].
        var sourceFractionStart: Double
        var sourceFractionEnd: Double
        /// Output time factor. 1.0 → real time; 0.4 → 40% (slow-mo);
        /// 1.6 → fast.
        var factor: Double
    }
    var segments: [Segment]

    /// Real-time no-op curve.
    static let realTime = SpeedCurve(segments: [
        .init(sourceFractionStart: 0, sourceFractionEnd: 1, factor: 1)
    ])

    func renderedDuration(forSource src: Double) -> Double {
        guard src > 0 else { return 0 }
        var rendered: Double = 0
        for s in segments {
            let segSource = src * (s.sourceFractionEnd - s.sourceFractionStart)
            // Factor < 1 stretches time (slow-mo); > 1 compresses.
            rendered += segSource / max(0.01, s.factor)
        }
        return rendered
    }
}

// MARK: - Transitions

enum TransitionKind: String, Codable {
    /// Hard cut, no blend (still snapped to the beat grid).
    case hardCut
    /// Cross-fade between A and B over the boundary window.
    case crossDissolve
    /// Whip-pan: directional motion blur on A, scaled-pan on B.
    case whipPan
    /// Zoom-punch: A scales up fast, B starts oversized and settles.
    case zoomPunch
    /// Light-leak wipe: bright additive bloom sweeps A out, B in.
    case lightLeakWipe
    /// Fade from / to solid black. Reserved for opening + closing.
    case fadeFromBlack
    case fadeToBlack
    /// Single-frame white-flash punctuation. Used by the
    /// "trendy-transitions" template on the highest-energy beat.
    /// When the compositor doesn't implement it yet, falls back to
    /// .hardCut (still snaps to the beat).
    case flash
}

// MARK: - Title cards

struct TitleCardSpec {
    var primaryText: String      // e.g. "MARCUS"
    var secondaryText: String    // e.g. "#23 · MAR 14"
    /// Hex string e.g. "#FF6A1F" — usually the jersey color.
    var accentHex: String

    static let duration: Double = 2.0
}

struct LowerThirdSpec {
    var primaryText: String
    var secondaryText: String
    /// When (within the first body clip) to slide in, in seconds.
    var startOffset: Double = 0.3
    /// How long the lower-third is visible before sliding out.
    var visibleDuration: Double = 2.0
}

struct ClosingCardSpec {
    var primaryText: String      // "PlayerCut"
    var secondaryText: String    // formatted date

    static let duration: Double = 1.5
}
