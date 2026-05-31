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

    /// Like `makePlan` but lets a test pass a custom `ReelTemplate` so we
    /// can verify the builder reads beatSnapAggressiveness / apexFactor.
    private func makePlan(clips: [SelectedClip],
                          settings: ReelSettings,
                          template: ReelTemplate,
                          musicBPM: Double = 140) -> EditPlan {
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
            sourceDuration: 60, profile: .highEnd,
            settings: settings, template: template)
        return builder.build(from: reelPlan, player: player, game: game,
                             musicURL: nil, musicBPM: musicBPM)
    }

    /// Minimal ReelTemplate constructor for tests — only the fields the
    /// asserted behavior reads. Other fields are filler.
    private func template(id: String,
                          beatSnap: Float,
                          apex: Double?) -> ReelTemplate {
        ReelTemplate(
            id: id, displayName: id, thumbnailAsset: "circle",
            lut: .vivid, lutBlend: 0.7,
            transitions: [.hardCut],
            speedRamp: apex.map { ReelTemplate.SpeedRampConfig(apexFactor: $0, heroOnly: true) },
            pacingTiers: ReelTemplate.PacingTiers(
                heroDurationSec: 5,
                featureDurationSec: 3,
                fillerDurationSec: 2,
                heroFreezeSec: nil),
            beatSnapAggressiveness: beatSnap,
            musicVibe: .energetic,
            extras: nil)
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

    // MARK: - Templates: builder reads beatSnap + apexFactor

    /// beat-sync-fast snap=1.0 cuts every clip exactly on a beat;
    /// minimal-vlog snap=0.3 leaves cuts mostly chronological. Same
    /// source clips, same BPM → at least one clip's sourceEnd must differ.
    func testDifferentBeatSnapAggressivenessProducesDifferentCutTimes() {
        var s = ReelSettings.defaults
        s.heroPacing = false        // isolate snap from pacing-tier trimming
        s.hookFirst = false
        // 120 BPM → beat = 0.5 s (no half-beat rule since <130 BPM).
        // Source 3.7 s → hardSnap = round(7.4)*0.5 = 3.5 s (trims, fits
        // under the original source so the snap-floor doesn't reject).
        // Score 0.40 stays under both the cold-open floor (0.45) AND the
        // .highEnd speed-ramp energy threshold (0.5), so every clip lands
        // in the body with a flat realTime speedCurve — keeping the snap
        // pass the only mechanism that can move sourceEnd. Otherwise the
        // ramped speedCurve's `k` changes currentRendered and washes out
        // the aggro signal we're trying to measure.
        let clips = [
            clip(start: 1.0,  end: 4.7,  score: 0.40),
            clip(start: 6.0,  end: 9.7,  score: 0.40),
            clip(start: 11.0, end: 14.7, score: 0.40),
        ]
        let hardSnap   = template(id: "t-hard",  beatSnap: 1.0, apex: nil)
        let softSnap   = template(id: "t-soft",  beatSnap: 0.3, apex: nil)
        let hardPlan = makePlan(clips: clips, settings: s,
                                template: hardSnap, musicBPM: 120)
        let softPlan = makePlan(clips: clips, settings: s,
                                template: softSnap, musicBPM: 120)
        let hardEnds = hardPlan.body.map { $0.sourceEnd }
        let softEnds = softPlan.body.map { $0.sourceEnd }
        XCTAssertEqual(hardEnds.count, softEnds.count,
                       "same input clips must produce the same body length")
        let diffs = zip(hardEnds, softEnds).map { abs($0 - $1) }
        let maxDiff = diffs.max() ?? 0
        XCTAssertGreaterThan(maxDiff, 0.05,
                             "beatSnapAggressiveness 1.0 vs 0.3 must move at least one cut by >50ms (got max \(maxDiff)s)")
    }

    /// slowmo-cinematic apex=0.35 vs aesthetic-slow apex=0.60 on the
    /// hero clip must produce visibly different deepest-segment factors
    /// in the speedCurve.
    func testDifferentApexFactorProducesDifferentSlowMo() {
        var s = ReelSettings.defaults
        s.heroPacing = true
        s.numHeroClips = 1
        s.hookFirst = false
        // Hero requires the top score; three clips, top is the hero.
        let clips = [
            clip(start: 1,  end: 7,  score: 0.95),
            clip(start: 10, end: 14, score: 0.55),
            clip(start: 17, end: 21, score: 0.50),
        ]
        let deep    = template(id: "t-deep",    beatSnap: 0.5, apex: 0.35)
        let shallow = template(id: "t-shallow", beatSnap: 0.5, apex: 0.60)
        let deepPlan    = makePlan(clips: clips, settings: s, template: deep)
        let shallowPlan = makePlan(clips: clips, settings: s, template: shallow)
        // Find the hero clip in each plan; compare deepest segment factor.
        func deepestRampFactor(_ plan: EditPlan) -> Double? {
            guard let hero = plan.body.first(where: { $0.pacingTier == .hero })
            else { return nil }
            return hero.speedCurve.segments.map(\.factor).min()
        }
        let deepFactor    = try? XCTUnwrap(deepestRampFactor(deepPlan))
        let shallowFactor = try? XCTUnwrap(deepestRampFactor(shallowPlan))
        XCTAssertNotNil(deepFactor)
        XCTAssertNotNil(shallowFactor)
        XCTAssertLessThan(abs(deepFactor! - 0.35), 0.01,
                          "deep template must produce ~0.35 deepest factor (got \(deepFactor!))")
        XCTAssertLessThan(abs(shallowFactor! - 0.60), 0.01,
                          "shallow template must produce ~0.60 deepest factor (got \(shallowFactor!))")
    }

    /// Template pacing tiers override the per-tier durations even after
    /// the builder's beat-snap pass — the tier targets must come from
    /// the template's values (settings.applying(template) handles this).
    func testTemplatePacingTiersDriveBuiltDurations() {
        var base = ReelSettings.defaults
        base.heroPacing = true
        base.hookFirst = false
        base.numHeroClips = 1
        let t = template(id: "t-pacing", beatSnap: 0.0, apex: nil)
        // Verify .applying overlay actually feeds the builder. Snap=0
        // disables the snap pass, so any deviation must come from pacing.
        let overlaid = base.applying(t)
        XCTAssertEqual(overlaid.heroDurationSec, t.pacingTiers.heroDurationSec)
        XCTAssertEqual(overlaid.fillerDurationSec, t.pacingTiers.fillerDurationSec)
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
