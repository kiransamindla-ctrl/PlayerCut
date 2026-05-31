//
//  ParticleOptInTests.swift
//  PlayerCutTests
//
//  Validates PR #11 S4 — particle layer composite opt-in.
//

import XCTest
@testable import PlayerCut

@MainActor
final class ParticleOptInTests: XCTestCase {

    /// Every particle kind ships an opacity in (0, 0.30] per spec —
    /// particles must never obscure the subject.
    func testEveryParticleCompositeAlphaIsCapped() {
        for k in ParticleKind.allCases {
            XCTAssertGreaterThan(k.compositeAlpha, 0,
                                 "\(k.rawValue) composite alpha must be > 0")
            XCTAssertLessThanOrEqual(k.compositeAlpha, 0.30,
                                     "\(k.rawValue) composite alpha must be ≤ 0.30 (got \(k.compositeAlpha))")
        }
    }

    /// Each template's declared particle field reaches MetalPetalInstruction
    /// via ClipPlan.particles → the compositor's particleImage call. We
    /// verify the wire-through is correct at the type level by reading
    /// the field on a sample ClipPlan after assignment.
    func testClipPlanCarriesParticles() {
        var clip = ClipPlan(id: UUID(),
                            sourceStart: 0, sourceEnd: 3,
                            cropKeyframes: [],
                            speedCurve: .realTime,
                            outgoingTransition: .hardCut,
                            energy: 0.5)
        XCTAssertNil(clip.particles,
                     "ClipPlan default particles must be nil (opt-in)")
        clip.particles = .filmGrain
        XCTAssertEqual(clip.particles, .filmGrain)
    }

    /// Only the three opted-in templates declare particles; the other
    /// nine must keep nil. Catches a JSON-edit mistake where a particle
    /// is accidentally enabled for a template the spec calls for off.
    func testOnlyOptedInTemplatesShipParticles() {
        let expectedKinds: [String: ParticleKind] = [
            "viral-tiktok":       .sparkle,
            "cinematic-portrait": .filmGrain,
            "aesthetic-slow":     .dust,
        ]
        for t in TemplateRegistry.shared.list() {
            if let want = expectedKinds[t.id] {
                XCTAssertEqual(t.extras?.particles, want,
                               "template \(t.id) particle mismatch")
            } else {
                XCTAssertNil(t.extras?.particles,
                             "template \(t.id) must NOT ship particles")
            }
        }
    }
}
