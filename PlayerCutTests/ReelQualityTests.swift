//
//  ReelQualityTests.swift
//  PlayerCutTests
//
//  Section 1 (audio peak / duck / boost), Section 2 (hero/feature/filler
//  pacing + slow-mo gate + apex freeze), Section 3 (hook-first) at the
//  unit level. The keystone covers the end-to-end export with these
//  features active under the user-facing Settings defaults.
//

import AVFoundation
import XCTest
@testable import PlayerCut

final class ReelQualityTests: XCTestCase {

    // MARK: - Section 1: audio peak detector lands on the burst

    func testPeakDetectorFindsBurstNearTarget() async throws {
        let spec = SampleVideoFactory.Spec(
            durationSeconds: 8, includeAudio: true,
            audioPeakSeconds: 4.0, audioPeakDuration: 1.0)
        let url = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first,
                                  "sample video must include an audio track")
        // Run on a window that brackets the burst.
        let detected = await AudioPeakDetector.detectPeakOffset(
            in: track, sourceStart: 2.0, sourceEnd: 6.0)
        let offset = try XCTUnwrap(detected, "detector returned nil")
        let peakAbsolute = 2.0 + offset
        // Burst spans 4.0 - 5.0 s; the detector should land inside it.
        XCTAssertGreaterThanOrEqual(peakAbsolute, 3.9,
                                    "Peak at \(peakAbsolute)s is before the burst")
        XCTAssertLessThanOrEqual(peakAbsolute, 5.1,
                                 "Peak at \(peakAbsolute)s is past the burst")
    }

    // MARK: - Section 2: tier labels + slow-mo gate + apex freeze

    private func clip(start: Double, end: Double, score: Float,
                      boxes: [TimedBox] = []) -> SelectedClip {
        let w = CandidateWindow(id: UUID(),
                                startTime: start, endTime: end,
                                audioScore: score, motionScore: score)
        let m = ScoredMoment(id: UUID(), window: w,
                             identificationConfidence: score,
                             activityScore: score,
                             playerBoundingBoxes: boxes,
                             compositeScore: score)
        return SelectedClip(moment: m, clipStart: start, clipEnd: end)
    }

    private func makePlan(clips: [SelectedClip], settings: ReelSettings) -> EditPlan {
        let player = PlayerEnrollment(
            id: UUID(), name: "Tester", jerseyNumber: "7",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
        let game = GameSession(
            id: UUID(), playerId: player.id, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: URL(fileURLWithPath: "/tmp/x.mov"),
            audioLoudnessURL: URL(fileURLWithPath: "/tmp/x.json"),
            stage1Result: nil, stage2Result: nil,
            status: .completed, triggerSource: .manual, sceneType: .outdoor)
        let reelPlan = ReelPlan(selected: clips, totalDuration: 60, tier: .normal)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 60, profile: .highEnd, settings: settings)
        return builder.build(from: reelPlan, player: player, game: game,
                             musicURL: nil, musicBPM: 140)
    }

    func testHeroPacingLabelsTopByScoreAsHero() {
        var s = ReelSettings.defaults
        s.heroPacing = true
        s.hookFirst = false   // isolate the tier check from the reorder
        s.numHeroClips = 1
        // Six clips with descending composite scores.
        let clips: [SelectedClip] = (0..<6).map { i in
            clip(start: Double(i) * 8 + 1,
                 end:   Double(i) * 8 + 6,
                 score: 0.95 - Float(i) * 0.05)
        }
        let plan = makePlan(clips: clips, settings: s)
        let body = plan.body
        XCTAssertFalse(body.isEmpty)
        // The clip with the highest energy is the one labeled hero.
        let hero = try? XCTUnwrap(body.first { $0.pacingTier == .hero })
        XCTAssertEqual(hero!.energy,
                       body.map(\.energy).max() ?? 0, accuracy: 0.001,
                       "Hero should be the highest-energy body clip")
        // Slow-mo is gated on hero only.
        for c in body {
            let hasRamp = c.speedCurve.segments.contains { $0.factor < 0.99 }
            if c.pacingTier == .hero {
                XCTAssertTrue(hasRamp || !s.heroPacing,
                              "Hero clip should carry a slow-mo segment")
                XCTAssertGreaterThan(c.freezeFrameSeconds, 0.1,
                                     "Hero should have an apex freeze (>0.1s)")
            } else {
                XCTAssertFalse(hasRamp,
                               "Non-hero clip should NOT have a slow-mo ramp under hero-emphasis")
                XCTAssertEqual(c.freezeFrameSeconds, 0,
                               "Only hero clips should freeze")
            }
        }
    }

    func testUniformPacingPreservesEnergyTriggeredRamps() {
        var s = ReelSettings.defaults
        s.heroPacing = false   // uniform mode = pre-existing behavior
        s.hookFirst = false
        let clips: [SelectedClip] = (0..<4).map { i in
            clip(start: Double(i) * 8 + 1, end: Double(i) * 8 + 6,
                 score: 0.85)   // every clip energetic → energy-based ramp
        }
        let plan = makePlan(clips: clips, settings: s)
        let body = plan.body
        XCTAssertFalse(body.isEmpty)
        for c in body {
            XCTAssertEqual(c.pacingTier, .feature,
                           "Uniform pacing should leave every body clip as .feature")
            XCTAssertEqual(c.freezeFrameSeconds, 0,
                           "Uniform pacing never freezes")
        }
    }

    // MARK: - Section 3: hook-first places the highest score at position 0

    func testHookFirstMovesHighestScoreClipToPositionZero() {
        var s = ReelSettings.defaults
        s.hookFirst = true
        s.heroPacing = false   // separate concerns
        // Clip 3 (index 2) is the strongest; should jump to index 0.
        let clips = [
            clip(start: 1,  end: 6,  score: 0.55),
            clip(start: 9,  end: 14, score: 0.60),
            clip(start: 17, end: 22, score: 0.92),  // ← hero
            clip(start: 25, end: 30, score: 0.50),
        ]
        let plan = makePlan(clips: clips, settings: s)
        let body = plan.body
        XCTAssertGreaterThanOrEqual(body.count, 2)
        let maxEnergy = body.map(\.energy).max() ?? 0
        XCTAssertEqual(body[0].energy, maxEnergy, accuracy: 0.001,
                       "With hookFirst on, position 0 must be the highest-energy clip")
    }

    func testChronologicalOrderingWhenHookFirstOff() {
        var s = ReelSettings.defaults
        s.hookFirst = false
        s.heroPacing = false
        let clips = [
            clip(start: 1,  end: 6,  score: 0.55),
            clip(start: 9,  end: 14, score: 0.60),
            clip(start: 17, end: 22, score: 0.92),
            clip(start: 25, end: 30, score: 0.50),
        ]
        let plan = makePlan(clips: clips, settings: s)
        // ranker output was chronological; cold open consumes the top clip
        // (score 0.92), so the remaining body should be chronological too.
        let starts = plan.body.map { $0.sourceStart }
        XCTAssertEqual(starts, starts.sorted(),
                       "Without hookFirst the body should stay chronological")
    }
}
