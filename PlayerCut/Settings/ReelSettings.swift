//
//  ReelSettings.swift
//  PlayerCut/Settings
//
//  Single source of truth for every user-tunable reel knob. Backed by
//  UserDefaults so the SwiftUI side can drive them with @AppStorage and
//  the compose path (ReelComposer / EditPlanBuilder) can read `.current`
//  without taking a SettingsView reference.
//
//  The TESTABILITY rule is enforced here: every new feature in Sections
//  1-3 (game-audio mix, hero/feature/filler pacing, hook-first ordering)
//  appears as a key in this file, gets a Settings toggle/slider in
//  SettingsView, and the compose path reads it on every reel — so the
//  user can A/B every feature from their phone the moment it ships.
//

import Foundation

enum ReelSettingsKeys {
    // Section 1 — game audio + ducking
    static let includeGameAudio  = "playercut.reel.includeGameAudio"   // Bool
    static let musicLevelDb      = "playercut.reel.musicLevelDb"       // Double (-12…0)
    static let gameAudioLevelDb  = "playercut.reel.gameAudioLevelDb"   // Double (-30…-6)
    static let duckDepthDb       = "playercut.reel.duckDepthDb"        // Double (3…12)
    static let gameAudioBoostDb  = "playercut.reel.gameAudioBoostDb"   // Double (0…9)

    // Section 2 — pacing tiers
    static let heroPacing        = "playercut.reel.heroPacing"         // Bool (true = hero-emphasis)
    static let heroDurationSec   = "playercut.reel.heroDurationSec"    // Double (3…7)
    static let fillerDurationSec = "playercut.reel.fillerDurationSec"  // Double (1.5…3.5)
    static let slowMoSpeed       = "playercut.reel.slowMoSpeed"        // Double (0.3…0.6)
    static let numHeroClips      = "playercut.reel.numHeroClips"       // Int (1 or 2)

    // Section 3 — order
    static let hookFirst         = "playercut.reel.hookFirst"          // Bool

    // CapCut-parity S1 — Background removal
    static let backgroundMode    = "playercut.reel.backgroundMode"     // String enum (BackgroundMode)
    static let forceSegAllClips  = "playercut.debug.forceSegAllClips"  // Bool
    static let showSegMask       = "playercut.debug.showSegMask"       // Bool

    // CapCut-parity S2 — Auto-captions
    static let captionsEnabled   = "playercut.reel.captionsEnabled"    // Bool
    static let captionLocale     = "playercut.debug.captionLocale"     // String (e.g. "auto", "en-US")
    static let captionPosition   = "playercut.debug.captionPosition"   // String enum (CaptionPosition)

    // CapCut-parity S5 — Stage 1 debug
    static let forceSceneType    = "playercut.debug.forceSceneType"    // String enum (SceneOverride)
    static let usePoseSignal     = "playercut.debug.usePoseSignal"     // Bool

    // Templates — selected ReelTemplate id (system-wide fallback when
    // the player has no defaultTemplateID). Empty string = use system default.
    static let selectedTemplateID = "playercut.reel.selectedTemplateID"  // String
}

/// Background-removal modes for the MetalPetal segmentation pass.
enum BackgroundMode: String, CaseIterable, Codable {
    case off    // no segmentation
    case cutout // person over blurred-background plate
    case pop    // graded person over mildly-graded background
    case auto   // engine picks per clip (cutout on hero, pop on feature, off on filler)
}

enum CaptionPosition: String, CaseIterable, Codable {
    case bottom, middle, top
}

enum SceneOverride: String, CaseIterable, Codable {
    case auto, indoor, outdoor, stadium
}

/// Snapshot of every reel-tuning knob, read fresh per compose so the
/// user's live Settings edits take effect on the next reel.
struct ReelSettings: Equatable {

    // MARK: - 1. Audio
    var includeGameAudio: Bool
    /// Music bed base level, dB. Prompt: -6 … -3 dB.
    var musicLevelDb: Double
    /// Game-audio base level, dB. Prompt: -24 … -18 dB.
    var gameAudioLevelDb: Double
    /// How far to duck the music on a detected peak, dB. Prompt: 6.
    var duckDepthDb: Double
    /// How far to boost the game audio on the same peak, dB. Prompt: 3-6.
    var gameAudioBoostDb: Double

    // MARK: - 2. Pacing
    var heroPacing: Bool
    var heroDurationSec: Double
    var fillerDurationSec: Double
    var slowMoSpeed: Double
    var numHeroClips: Int

    // MARK: - 3. Order
    var hookFirst: Bool

    // MARK: - CapCut-parity S1 — Background removal
    var backgroundMode: BackgroundMode
    var forceSegAllClips: Bool   // debug
    var showSegMask: Bool        // debug

    // MARK: - CapCut-parity S2 — Auto-captions
    var captionsEnabled: Bool
    var captionLocale: String    // "auto" or a BCP-47 like "en-US"
    var captionPosition: CaptionPosition

    // MARK: - CapCut-parity S5 — Stage 1
    var forceSceneType: SceneOverride
    var usePoseSignal: Bool

    // MARK: - Templates
    /// Selected `ReelTemplate.id`. Empty string = use system default
    /// (`TemplateRegistry.defaultTemplateID`) or the player's per-profile
    /// override when one is set.
    var selectedTemplateID: String

    // MARK: - Defaults — Default-ON-for-quality-wins per project rules
    static let defaults = ReelSettings(
        includeGameAudio:  true,
        musicLevelDb:      -4.5,
        gameAudioLevelDb:  -21,
        duckDepthDb:        6,
        gameAudioBoostDb:   5,
        heroPacing:         true,
        heroDurationSec:    5.0,
        fillerDurationSec:  2.5,
        slowMoSpeed:        0.4,
        numHeroClips:       1,
        hookFirst:          true,
        backgroundMode:     .off,           // perf-conservative default; user opts in via Settings → Effects
        forceSegAllClips:   false,
        showSegMask:        false,
        captionsEnabled:    true,           // default-ON for quality win
        captionLocale:      "auto",
        captionPosition:    .bottom,
        forceSceneType:     .auto,
        usePoseSignal:      true,
        selectedTemplateID: "")           // empty = use system / per-player default

    /// Fresh read from UserDefaults. Each compose() picks up the user's
    /// latest A/B settings without needing a relaunch.
    static var current: ReelSettings {
        let d = UserDefaults.standard
        let base = ReelSettings.defaults
        return ReelSettings(
            includeGameAudio:
                d.object(forKey: ReelSettingsKeys.includeGameAudio)  as? Bool   ?? base.includeGameAudio,
            musicLevelDb:
                d.object(forKey: ReelSettingsKeys.musicLevelDb)      as? Double ?? base.musicLevelDb,
            gameAudioLevelDb:
                d.object(forKey: ReelSettingsKeys.gameAudioLevelDb)  as? Double ?? base.gameAudioLevelDb,
            duckDepthDb:
                d.object(forKey: ReelSettingsKeys.duckDepthDb)       as? Double ?? base.duckDepthDb,
            gameAudioBoostDb:
                d.object(forKey: ReelSettingsKeys.gameAudioBoostDb)  as? Double ?? base.gameAudioBoostDb,
            heroPacing:
                d.object(forKey: ReelSettingsKeys.heroPacing)        as? Bool   ?? base.heroPacing,
            heroDurationSec:
                d.object(forKey: ReelSettingsKeys.heroDurationSec)   as? Double ?? base.heroDurationSec,
            fillerDurationSec:
                d.object(forKey: ReelSettingsKeys.fillerDurationSec) as? Double ?? base.fillerDurationSec,
            slowMoSpeed:
                d.object(forKey: ReelSettingsKeys.slowMoSpeed)       as? Double ?? base.slowMoSpeed,
            numHeroClips:
                d.object(forKey: ReelSettingsKeys.numHeroClips)      as? Int    ?? base.numHeroClips,
            hookFirst:
                d.object(forKey: ReelSettingsKeys.hookFirst)         as? Bool   ?? base.hookFirst,
            backgroundMode:
                BackgroundMode(rawValue: d.string(forKey: ReelSettingsKeys.backgroundMode) ?? "")
                    ?? base.backgroundMode,
            forceSegAllClips:
                d.object(forKey: ReelSettingsKeys.forceSegAllClips)  as? Bool   ?? base.forceSegAllClips,
            showSegMask:
                d.object(forKey: ReelSettingsKeys.showSegMask)       as? Bool   ?? base.showSegMask,
            captionsEnabled:
                d.object(forKey: ReelSettingsKeys.captionsEnabled)   as? Bool   ?? base.captionsEnabled,
            captionLocale:
                d.string(forKey: ReelSettingsKeys.captionLocale)            ?? base.captionLocale,
            captionPosition:
                CaptionPosition(rawValue: d.string(forKey: ReelSettingsKeys.captionPosition) ?? "")
                    ?? base.captionPosition,
            forceSceneType:
                SceneOverride(rawValue: d.string(forKey: ReelSettingsKeys.forceSceneType) ?? "")
                    ?? base.forceSceneType,
            usePoseSignal:
                d.object(forKey: ReelSettingsKeys.usePoseSignal)     as? Bool   ?? base.usePoseSignal,
            selectedTemplateID:
                d.string(forKey: ReelSettingsKeys.selectedTemplateID)       ?? base.selectedTemplateID)
    }

    /// Returns a copy of `self` with pacing / hero-freeze / background-mode
    /// fields replaced by the template's values. Captions stay opt-in via
    /// the template's `extras.captionsEnabled` (nil = honor the global
    /// setting). Used by PipelineOrchestrator at compose time so the
    /// active template's pacing reaches EditPlanBuilder + ReelComposer
    /// without rewriting their read-from-defaults pattern.
    func applying(_ template: ReelTemplate?) -> ReelSettings {
        guard let t = template else { return self }
        var copy = self
        copy.heroDurationSec   = t.pacingTiers.heroDurationSec
        copy.fillerDurationSec = t.pacingTiers.fillerDurationSec
        if let ext = t.extras {
            if let cap = ext.captionsEnabled { copy.captionsEnabled = cap }
            // PR #11 — backgroundMode precedence:
            //   user-global ∈ {off, cutout, pop} → user wins (explicit choice).
            //   user-global == .auto → template's declared mode wins.
            // This lets a parent turn segmentation off globally for kids'
            // content without having to fight per-template defaults.
            if let bg = ext.backgroundMode, self.backgroundMode == .auto {
                copy.backgroundMode = bg
            }
        }
        return copy
    }

    /// dB → linear gain helper used by both the audio mix and the tests.
    static func linearGain(db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }
}
