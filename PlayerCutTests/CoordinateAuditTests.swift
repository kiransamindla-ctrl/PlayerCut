//
//  CoordinateAuditTests.swift
//  PlayerCutTests
//
//  Validates the normalized-coordinate predicates that gate the
//  MetalPetalCompositor crop path (Section 6). We test the pure
//  `is…` form rather than the trapping `assert…` form so XCTest
//  doesn't crash in debug — but the production crop site still
//  calls `assertNormalizedCenter` on every keyframe, so any
//  upstream regression that produces out-of-range coords trips
//  the trap in CI / dev builds.
//

import XCTest
@testable import PlayerCut

final class CoordinateAuditTests: XCTestCase {

    // MARK: - CGPoint center

    func testCenterAtOriginIsNormalized() {
        XCTAssertTrue(MetalPetalCompositor.isNormalizedCenter(.zero))
    }

    func testCenterAtUnitIsNormalized() {
        XCTAssertTrue(MetalPetalCompositor.isNormalizedCenter(.init(x: 1, y: 1)))
    }

    func testCenterPastUnitFails() {
        XCTAssertFalse(MetalPetalCompositor.isNormalizedCenter(.init(x: 1.0001, y: 0.5)))
    }

    func testCenterNegativeFails() {
        XCTAssertFalse(MetalPetalCompositor.isNormalizedCenter(.init(x: 0.5, y: -0.01)))
    }

    // MARK: - CGRect

    /// Mirrors the spec example: x=0.9, w=0.5 → overflows the right edge.
    func testRectOverflowingRightEdgeFails() {
        let r = CGRect(x: 0.9, y: 0.1, width: 0.5, height: 0.2)
        XCTAssertFalse(MetalPetalCompositor.isNormalizedRect(r),
                       "x=\(r.origin.x) + w=\(r.size.width) > 1 must reject")
    }

    func testRectOverflowingBottomEdgeFails() {
        let r = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.5)
        XCTAssertFalse(MetalPetalCompositor.isNormalizedRect(r))
    }

    func testRectExactlyAtUnitPasses() {
        let r = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        XCTAssertTrue(MetalPetalCompositor.isNormalizedRect(r))
    }

    func testRectWithinUnitPasses() {
        let r = CGRect(x: 0.25, y: 0.10, width: 0.50, height: 0.80)
        XCTAssertTrue(MetalPetalCompositor.isNormalizedRect(r))
    }

    func testRectNegativeOriginFails() {
        let r = CGRect(x: -0.01, y: 0.10, width: 0.50, height: 0.80)
        XCTAssertFalse(MetalPetalCompositor.isNormalizedRect(r))
    }

    /// 1e-4 epsilon — Vision occasionally produces (x+w) like 1.00003 due
    /// to floating-point rounding. Should still count as in-range.
    func testRectAtEpsilonOverflowPasses() {
        let r = CGRect(x: 0.6, y: 0.0, width: 0.40005, height: 1.0)
        XCTAssertTrue(MetalPetalCompositor.isNormalizedRect(r),
                      "x+w=\(r.origin.x + r.size.width) should be tolerated under the 1e-4 epsilon")
    }
}
