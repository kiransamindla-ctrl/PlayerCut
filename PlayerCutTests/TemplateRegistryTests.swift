//
//  TemplateRegistryTests.swift
//  PlayerCutTests
//
//  Validates Templates.json round-trips, all 6 starting templates
//  decode without missing fields, and the resolver falls back through
//  player-default → settings-selected → system-default correctly.
//

import XCTest
@testable import PlayerCut

@MainActor
final class TemplateRegistryTests: XCTestCase {

    func testAllTwelveTemplatesLoadFromManifest() throws {
        let templates = TemplateRegistry.shared.list()
        XCTAssertEqual(templates.count, 12,
                       "Templates.json must hold exactly 12 presets after PR #11")
    }

    func testEachExpectedIDIsPresent() throws {
        let expected: Set<String> = [
            "beat-sync-fast",
            "slowmo-cinematic",
            "minimal-vlog",
            "trendy-transitions",
            "attitude-montage",
            "aesthetic-slow",
            "epic-highlight",
            "storytelling-narrative",
            "viral-tiktok",
            "cinematic-portrait",
            "energy-montage",
            "clean-social",
        ]
        let actual = Set(TemplateRegistry.shared.list().map { $0.id })
        XCTAssertEqual(actual, expected,
                       "missing or extra templates: \(actual.symmetricDifference(expected))")
    }

    // MARK: - PR #11 — per-template background mode + particle opt-in

    func testEveryTemplateDeclaresBackgroundMode() throws {
        for t in TemplateRegistry.shared.list() {
            XCTAssertNotNil(t.extras?.backgroundMode,
                            "template \(t.id) must declare extras.backgroundMode")
        }
    }

    func testGlobalBackgroundSettingOverridesTemplateExceptInAuto() throws {
        let aestheticSlow = try XCTUnwrap(
            TemplateRegistry.shared.get(id: "aesthetic-slow"))
        XCTAssertEqual(aestheticSlow.extras?.backgroundMode, .pop)

        // Global = .auto → template wins.
        var s = ReelSettings.defaults
        s.backgroundMode = .auto
        let autoOverlay = s.applying(aestheticSlow)
        XCTAssertEqual(autoOverlay.backgroundMode, .pop,
                       "global .auto must honor template's .pop")

        // Global = .off → global wins (user explicitly turned segmentation off).
        s.backgroundMode = .off
        let offOverlay = s.applying(aestheticSlow)
        XCTAssertEqual(offOverlay.backgroundMode, .off,
                       "global .off overrides template's per-template default")
    }

    func testParticleOptInRespectsTemplate() throws {
        let viral = try XCTUnwrap(TemplateRegistry.shared.get(id: "viral-tiktok"))
        XCTAssertEqual(viral.extras?.particles, .sparkle)
        let portrait = try XCTUnwrap(TemplateRegistry.shared.get(id: "cinematic-portrait"))
        XCTAssertEqual(portrait.extras?.particles, .filmGrain)
        let aesthetic = try XCTUnwrap(TemplateRegistry.shared.get(id: "aesthetic-slow"))
        XCTAssertEqual(aesthetic.extras?.particles, .dust)
        // The other 9 templates declare nil particles.
        for t in TemplateRegistry.shared.list()
        where !["viral-tiktok", "cinematic-portrait", "aesthetic-slow"]
                .contains(t.id) {
            XCTAssertNil(t.extras?.particles,
                         "template \(t.id) should ship no particles")
        }
    }

    func testSystemDefaultResolves() throws {
        let t = TemplateRegistry.shared.resolve(playerDefaultID: nil,
                                                settingsSelectedID: nil)
        XCTAssertEqual(t?.id, TemplateRegistry.defaultTemplateID)
    }

    func testPlayerDefaultBeatsSettingsSelected() throws {
        let t = TemplateRegistry.shared.resolve(
            playerDefaultID: "minimal-vlog",
            settingsSelectedID: "beat-sync-fast")
        XCTAssertEqual(t?.id, "minimal-vlog",
                       "player.defaultTemplateID must win over Settings.selectedTemplateID")
    }

    func testSettingsSelectedUsedWhenPlayerHasNone() throws {
        let t = TemplateRegistry.shared.resolve(
            playerDefaultID: nil,
            settingsSelectedID: "aesthetic-slow")
        XCTAssertEqual(t?.id, "aesthetic-slow")
    }

    func testUnknownIDFallsThroughToSystemDefault() throws {
        let t = TemplateRegistry.shared.resolve(
            playerDefaultID: "does-not-exist",
            settingsSelectedID: "also-bogus")
        XCTAssertEqual(t?.id, TemplateRegistry.defaultTemplateID)
    }

    // MARK: - Template field sanity

    func testEveryTemplateHasNonEmptyTransitionsAndPacing() throws {
        for t in TemplateRegistry.shared.list() {
            XCTAssertFalse(t.transitions.isEmpty,
                           "\(t.id) ships no transitions")
            XCTAssertGreaterThan(t.pacingTiers.heroDurationSec, 0,
                                 "\(t.id) hero duration must be positive")
            XCTAssertGreaterThan(t.pacingTiers.featureDurationSec, 0,
                                 "\(t.id) feature duration must be positive")
            XCTAssertGreaterThan(t.pacingTiers.fillerDurationSec, 0,
                                 "\(t.id) filler duration must be positive")
            XCTAssertGreaterThanOrEqual(t.lutBlend, 0)
            XCTAssertLessThanOrEqual(t.lutBlend, 1)
            XCTAssertGreaterThanOrEqual(t.beatSnapAggressiveness, 0)
            XCTAssertLessThanOrEqual(t.beatSnapAggressiveness, 1)
        }
    }

    // MARK: - applying() overlay

    func testReelSettingsApplyingOverridesPacingFromTemplate() throws {
        guard let t = TemplateRegistry.shared.get(id: "aesthetic-slow") else {
            XCTFail("aesthetic-slow template missing")
            return
        }
        // PR #11 — to receive the template's backgroundMode override the
        // global setting must be .auto (the new precedence rule). The
        // pacing fields always overlay regardless of global state.
        var base = ReelSettings.defaults
        base.backgroundMode = .auto
        let overlaid = base.applying(t)
        XCTAssertEqual(overlaid.heroDurationSec, t.pacingTiers.heroDurationSec)
        XCTAssertEqual(overlaid.fillerDurationSec, t.pacingTiers.fillerDurationSec)
        XCTAssertEqual(overlaid.backgroundMode, .pop,
                       "aesthetic-slow's backgroundMode .pop must apply under global .auto")
    }

    func testReelSettingsApplyingNilTemplateIsIdentity() throws {
        let base = ReelSettings.defaults
        let overlaid = base.applying(nil)
        XCTAssertEqual(overlaid, base)
    }
}
