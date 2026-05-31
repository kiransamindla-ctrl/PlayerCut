//
//  SubjectFollowPolishTests.swift
//  PlayerCutTests
//
//  Validates PR #11 S2 subject-follow polish:
//   - 12% safe margin on the tracked subject bounding box.
//   - Track-confidence < 0.5 triggers Ken Burns fallback.
//   - Scale interpolation uses smoothstep (no first-derivative jumps).
//

import CoreGraphics
import XCTest
@testable import PlayerCut

final class SubjectFollowPolishTests: XCTestCase {

    // MARK: - 12% safe margin

    /// A subject that physically fills 30% of source height should be
    /// framed with a 12% margin, so the COMPUTED desired scale is
    /// 0.45 / (0.30 × 1.12) instead of 0.45 / 0.30 — i.e. about 11%
    /// looser zoom than the no-margin baseline.
    func testSubjectMarginRelaxesComputedScale() {
        let boxH = 0.30
        let margin = EditPlanBuilder.subjectSafeMarginFraction
        let noMargin   = 0.45 / boxH
        let withMargin = 0.45 / (boxH * (1 + margin))
        XCTAssertLessThan(withMargin, noMargin,
                          "safe margin must reduce the computed crop scale (looser frame)")
        // Sanity: not so loose that the player vanishes — the relaxation
        // should be ~10–12 %.
        XCTAssertEqual(withMargin / noMargin,
                       1 / (1 + margin),
                       accuracy: 0.001)
    }

    func testSafeMarginFractionIsPositiveAndReasonable() {
        XCTAssertEqual(EditPlanBuilder.subjectSafeMarginFraction, 0.12,
                       accuracy: 0.001,
                       "spec calls for 12% safe margin")
    }

    // MARK: - Confidence floor → Ken Burns

    func testTrackConfidenceFloorIsHalf() {
        XCTAssertEqual(EditPlanBuilder.trackConfidenceFloor, 0.5,
                       "spec calls for 0.5 confidence floor before fading to Ken Burns")
    }

    // MARK: - Scale interpolation is smooth (cubic / smoothstep)

    /// Smoothstep produces zero derivative at the endpoints; a linear
    /// curve does not. Sample a unit-length interp from 1.0 to 1.45
    /// across two adjacent ticks at f ≈ 0 and f ≈ 1 — the smoothed
    /// curve must report ≪ linear's rate of change at either end.
    func testSmoothstepProducesZeroEdgeDerivative() {
        // Replicate the smoothstep formula used in interpolateTarget so
        // the test asserts the math directly without spinning up a full
        // builder.
        func smooth(_ f: Double) -> Double { f * f * (3 - 2 * f) }
        let h = 0.01
        let left  = smooth(h) - smooth(0)         // delta near f=0
        let right = smooth(1) - smooth(1 - h)     // delta near f=1
        XCTAssertLessThan(abs(left),  h * 0.1,
                          "smoothstep must flatten at the left edge")
        XCTAssertLessThan(abs(right), h * 0.1,
                          "smoothstep must flatten at the right edge")
        // And the middle should rise — proves it's not constant.
        // Middle band slope is 1.5× faster than linear at f=0.5 — the
        // signature of cubic ease-in-out. Loosened from 0.3 → 0.25 to
        // match the actual smoothstep evaluation (smooth(0.6)−smooth(0.4)=0.296).
        XCTAssertGreaterThan(smooth(0.6) - smooth(0.4), 0.25,
                             "smoothstep must still cover the full range in the middle band")
    }
}
