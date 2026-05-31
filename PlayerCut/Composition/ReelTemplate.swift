//
//  ReelTemplate.swift
//  PlayerCut/Composition
//
//  A reel preset: a single tap that locks LUT, transitions, pacing,
//  beat-snap aggressiveness, music vibe, and overlay style. The
//  six starting templates ship in Resources/Templates.json and are
//  loaded once at startup by `TemplateRegistry`.
//
//  Templates are a thin overlay on the existing EditPlanBuilder
//  + ReelComposer pipeline. EditPlanBuilder reads pacing / beat-snap
//  / look-up-table fields off the template when one is supplied;
//  falls back to ReelSettings + EditStyle when no template is set
//  (so existing test fixtures and the no-preset path still work).
//

import Foundation

/// Codable preset that captures every editor decision a user might want
/// to tap from a thumbnail gallery. JSON-loaded so the engineering team
/// can ship new templates without recompiling.
struct ReelTemplate: Codable, Identifiable, Equatable {

    let id: String
    let displayName: String
    /// SF Symbol or bundled image name shown in the thumbnail gallery.
    /// SF Symbols ship with the OS so we don't block the first PR on
    /// having pre-rendered keystone thumbnails.
    let thumbnailAsset: String

    /// Picks the existing `ColorLook` cube in LUTFactory. New cases
    /// (punchy, soft) are added alongside the existing four.
    let lut: ColorLook
    /// 0…1 blend ratio between source and graded image. CapCut-style
    /// templates run ≥ 0.6; "minimal-vlog" runs 0.5 for restraint.
    let lutBlend: Float

    /// Allowed transitions for clip boundaries. EditPlanBuilder rotates
    /// through this list, escalating on high-energy boundaries.
    let transitions: [TransitionKind]

    /// When non-nil, EditPlanBuilder applies a speed ramp on the hero
    /// (and optionally feature) clip(s). Nil = no ramps.
    let speedRamp: SpeedRampConfig?

    /// Pacing tier durations. EditPlanBuilder reads these instead of
    /// the ReelSettings defaults when a template is active.
    let pacingTiers: PacingTiers

    /// 0 = strictly chronological, 1 = snap every cut to the nearest
    /// beat. Used by EditPlanBuilder.snapToBeatGrid to weight the
    /// snap vs. preserve-anchor tradeoff.
    let beatSnapAggressiveness: Float

    /// Which Pixabay music pool to draw from. Falls back to player's
    /// stored preference when nil.
    let musicVibe: MusicVibe

    /// Optional template-only toggles. Captions on/off lets a template
    /// like "minimal-vlog" enable them even when ReelSettings has them
    /// off; segmentationMode lets "aesthetic-slow" force background pop.
    let extras: TemplateExtras?

    // MARK: - Nested types

    struct PacingTiers: Codable, Equatable {
        var heroDurationSec: Double
        var featureDurationSec: Double
        var fillerDurationSec: Double
        /// Optional apex freeze on the hero clip. nil = use ReelSettings
        /// default; 0 = explicitly disable; positive = forced freeze.
        var heroFreezeSec: Double?
    }

    struct SpeedRampConfig: Codable, Equatable {
        /// Apex slow-mo factor. 0.4 = 40% real-time (typical hero shot).
        var apexFactor: Double
        /// True = apply the ramp on hero clips only; false = hero + first
        /// feature. The 6 starting templates use heroOnly = true except
        /// "aesthetic-slow" (across hero + feature).
        var heroOnly: Bool
    }

    struct TemplateExtras: Codable, Equatable {
        /// Force captions on for this template even when global setting
        /// is off; nil = honor global.
        var captionsEnabled: Bool?
        /// Override background segmentation mode for this template;
        /// nil = honor ReelSettings.backgroundMode.
        var backgroundMode: BackgroundMode?
    }
}
