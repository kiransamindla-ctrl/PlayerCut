//
//  PlayerCutUITests.swift
//  PlayerCutUITests
//
//  Smoke tests against the simulator. We deliberately avoid full
//  end-to-end flows that depend on:
//   - Camera frames (simulator has no camera)
//   - Selfie face detection (no faces in the simulator)
//   - System permission prompts (handled by Springboard, brittle)
//
//  What we do verify, deterministically and on every CI run:
//   - The app launches without crashing
//   - The Enroll-a-player CTA is reachable from a clean install
//   - The Settings sheet opens from the toolbar gear
//   - Tapping Enroll presents the enrollment wizard (its step-title
//     identifier becomes visible)
//

import XCTest

final class PlayerCutUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip onboarding gates that would block these smoke tests.
        // Using -<key> <value> sets UserDefaults values for the
        // running test app process.
        app.launchArguments += [
            "-playercut.terms_accepted_v1", "YES",
            "-playercut.old_phone_intro_shown", "YES",
            "-playercut.permissions_primer_done", "YES",
            "-playercut.assisted_tier_shown", "YES"
        ]
        app.launch()
    }

    func testAppLaunches() {
        XCTAssertTrue(
            app.staticTexts["hero-title"].waitForExistence(timeout: 5),
            "Hero title (accessibilityIdentifier 'hero-title') should be visible on launch")
    }

    func testSettingsSheetOpens() {
        let gear = app.buttons["settings-gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5),
                      "Settings gear should be in the toolbar")
        gear.tap()
        XCTAssertTrue(app.navigationBars["SETTINGS"].waitForExistence(timeout: 3)
                      || app.staticTexts["SETTINGS"].waitForExistence(timeout: 3),
                      "Settings sheet should present with SETTINGS title")
    }

    func testEnrollSheetOpens() {
        // In a fresh install the empty-state CTA is reachable; in a
        // populated install we fall through to the in-list Add Player
        // row. Either entry point should land us on the enrollment
        // wizard, identified by its step-title accessibilityIdentifier.
        let enroll = app.buttons["enroll-player"]
        let addPlayer = app.buttons["add-player"]

        let entry: XCUIElement
        if enroll.waitForExistence(timeout: 3) {
            entry = enroll
        } else if addPlayer.waitForExistence(timeout: 3) {
            entry = addPlayer
        } else {
            XCTFail("Neither enroll-player nor add-player entry point exists")
            return
        }
        entry.tap()
        XCTAssertTrue(
            app.staticTexts["enrollment-step-title"].waitForExistence(timeout: 3),
            "Enrollment wizard should appear with a step title")
    }
}
