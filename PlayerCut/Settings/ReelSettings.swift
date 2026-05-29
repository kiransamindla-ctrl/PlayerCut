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

    // MARK: - Defaults that match the prompt's "best reel" recommendation
    static let defaults = ReelSettings(
        includeGameAudio:  true,
        musicLevelDb:      -4.5,    // mid of -6…-3
        gameAudioLevelDb:  -21,     // mid of -24…-18
        duckDepthDb:        6,
        gameAudioBoostDb:   5,      // mid of 3-6
        heroPacing:         true,
        heroDurationSec:    5.0,    // mid of 4-6
        fillerDurationSec:  2.5,    // mid of 2-3
        slowMoSpeed:        0.4,    // prompt: 0.4x at apex
        numHeroClips:       1,
        hookFirst:          true)

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
                d.object(forKey: ReelSettingsKeys.hookFirst)         as? Bool   ?? base.hookFirst)
    }

    /// dB → linear gain helper used by both the audio mix and the tests.
    static func linearGain(db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }
}
