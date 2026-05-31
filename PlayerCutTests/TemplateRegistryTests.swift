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

    func testAllSixStartingTemplatesLoad() throws {
        let templates = TemplateRegistry.shared.list()
        XCTAssertEqual(templates.count, 6,
                       "Templates.json must hold exactly 6 starting presets")
    }

    func testEachExpectedIDIsPresent() throws {
        let expected: Set<String> = [
            "beat-sync-fast",
            "slowmo-cinematic",
            "minimal-vlog",
            "trendy-transitions",
            "attitude-montage",
            "aesthetic-slow",
        ]
        let actual = Set(TemplateRegistry.shared.list().map { $0.id })
        XCTAssertEqual(actual, expected,
                       "missing or extra templates: \(actual.symmetricDifference(expected))")
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
        let base = ReelSettings.defaults
        let overlaid = base.applying(t)
        XCTAssertEqual(overlaid.heroDurationSec, t.pacingTiers.heroDurationSec)
        XCTAssertEqual(overlaid.fillerDurationSec, t.pacingTiers.fillerDurationSec)
        // aesthetic-slow forces backgroundMode = .pop in its extras.
        XCTAssertEqual(overlaid.backgroundMode, .pop)
    }

    func testReelSettingsApplyingNilTemplateIsIdentity() throws {
        let base = ReelSettings.defaults
        let overlaid = base.applying(nil)
        XCTAssertEqual(overlaid, base)
    }
}
