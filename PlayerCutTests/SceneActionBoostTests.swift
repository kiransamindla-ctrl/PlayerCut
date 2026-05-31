//
//  SceneActionBoostTests.swift
//  PlayerCutTests
//
//  Validates the per-window action-boost helper that promotes
//  candidate windows whose sampled frame's top-3 VNClassifyImage
//  labels carry a sports / action keyword.
//

import XCTest
import Vision
@testable import PlayerCut

final class SceneActionBoostTests: XCTestCase {

    // MARK: - actionBoost(forLabels:)

    func testNoActionLabelsReturnsUnitBoost() {
        let labels = [
            (identifier: "sky",  confidence: Float(0.82)),
            (identifier: "tree", confidence: Float(0.55)),
            (identifier: "road", confidence: Float(0.31)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels), 1.0,
                       "no action keyword → boost 1.0")
    }

    func testSingleActionLabelGivesMinBoost() {
        let labels = [
            (identifier: "stadium",   confidence: Float(0.85)),
            (identifier: "sky",       confidence: Float(0.45)),
            (identifier: "billboard", confidence: Float(0.35)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels),
                       SceneClassifier.actionBoostMin,
                       "one action keyword in top-3 → 1.2× boost")
    }

    func testTwoActionLabelsGiveMaxBoost() {
        let labels = [
            (identifier: "soccer_field", confidence: Float(0.78)),
            (identifier: "athlete",      confidence: Float(0.66)),
            (identifier: "crowd",        confidence: Float(0.50)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels),
                       SceneClassifier.actionBoostMax,
                       "≥2 action keywords in top-3 → 1.5× boost")
    }

    func testLowConfidenceActionLabelIgnored() {
        // sports_equipment at 0.18 is below the 0.30 floor — must NOT
        // trigger a boost on its own.
        let labels = [
            (identifier: "sky",              confidence: Float(0.82)),
            (identifier: "tree",             confidence: Float(0.55)),
            (identifier: "sports_equipment", confidence: Float(0.18)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels), 1.0,
                       "label below confidence floor must not boost")
    }

    func testOnlyTopThreeLabelsConsidered() {
        // First three are non-action; the action label at position 4
        // must be ignored even though its confidence clears the floor.
        let labels = [
            (identifier: "sky",      confidence: Float(0.82)),
            (identifier: "tree",     confidence: Float(0.55)),
            (identifier: "road",     confidence: Float(0.45)),
            (identifier: "stadium",  confidence: Float(0.40)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels), 1.0,
                       "action label outside top-3 must not boost")
    }

    func testKeywordMatchIsSubstring() {
        // "ball_game" should match the "ball_game" keyword; "play_park"
        // should match "play".
        let labels = [
            (identifier: "ball_game", confidence: Float(0.65)),
            (identifier: "play_park", confidence: Float(0.45)),
            (identifier: "fence",     confidence: Float(0.30)),
        ]
        XCTAssertEqual(SceneClassifier.actionBoost(forLabels: labels),
                       SceneClassifier.actionBoostMax,
                       "substring matches must count toward the action total")
    }
}
