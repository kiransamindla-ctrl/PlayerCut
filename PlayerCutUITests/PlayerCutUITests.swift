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
            "-playercut.assisted_tier_shown", "YES",
            // Seed a player so the populated home (Record game → pre-record
            // sheet) is reachable; camera-based enrollment can't run on the
            // simulator. Existing tests already handle the populated state.
            "-playercut.uitest_seed_player"
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

    // MARK: - #2 Diagnostics is dismissible

    func testDiagnosticsHasDoneButton() {
        let gear = app.buttons["settings-gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()

        let openDiag = app.buttons["open-diagnostics"]
        XCTAssertTrue(openDiag.waitForExistence(timeout: 3),
                      "Settings should have a Diagnostics entry")
        openDiag.tap()

        let done = app.buttons["diagnostics-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3),
                      "Diagnostics must have a Done button (it was a dead-end)")
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 2),
                       "Done should dismiss the Diagnostics screen")
    }

    // MARK: - #4 Pre-record sheet (length + vibe + tips) before the camera

    func testPreRecordSheetAppearsBeforeCamera() {
        let record = app.buttons["record-game"]
        XCTAssertTrue(record.waitForExistence(timeout: 5),
                      "Record game should be reachable with a player enrolled")
        record.tap()

        XCTAssertTrue(app.buttons["prerecord-continue"].waitForExistence(timeout: 3),
                      "Pre-record sheet (with Continue) should appear before the camera")
        XCTAssertTrue(app.segmentedControls["prerecord-length"].exists,
                      "Reel length picker should be on the sheet")
        XCTAssertTrue(app.buttons["prerecord-vibe-energetic"].exists,
                      "Music vibe chips should be on the sheet")
        // Quick-tips reminder text is present.
        XCTAssertTrue(app.staticTexts["QUICK TIPS"].exists
                      || app.staticTexts.containing(
                            NSPredicate(format: "label CONTAINS[c] 'landscape'")).count > 0,
                      "Quick tips should be shown on the sheet")
    }

    // MARK: - #3 Enrollment asks for a photo only once (jersey color = swatch)

    func testJerseyColorStepHasNoCamera() {
        let entry = app.buttons["add-player"].waitForExistence(timeout: 3)
            ? app.buttons["add-player"] : app.buttons["enroll-player"]
        entry.tap()
        XCTAssertTrue(app.staticTexts["enrollment-step-title"].waitForExistence(timeout: 3))

        // Step 1 — identity. Fill name + jersey number so Next enables.
        let name = app.textFields["Player name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("Sam")
        let jersey = app.textFields["23"]   // placeholder text
        if jersey.waitForExistence(timeout: 2) { jersey.tap(); jersey.typeText("9") }
        // Dismiss the number pad if present.
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }

        app.buttons["NEXT"].tap()   // PCPillButton uppercases its title

        // Step 2 — jersey color. Must be swatch-only: NO camera button here.
        // (The single photo lives on the next step, the selfie.)
        XCTAssertTrue(app.staticTexts["enrollment-step-title"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Take photo"].exists,
                       "Jersey color step must not open the camera (dedupe the second photo)")
    }
}
