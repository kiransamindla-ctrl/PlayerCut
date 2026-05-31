//
//  PipelinePerformanceTests.swift
//  PlayerCutTests
//
//  XCTest measure{} baselines for the three heavy pipeline stages.
//
//  WHAT THESE TESTS ARE FOR:
//    Catching *algorithmic* regressions — accidentally doubling the
//    work per frame, adding a quadratic loop, dropping a vDSP call
//    back to scalar Swift, etc. A change that makes a stage 2× slower
//    will show up as a measure{} regression on every CI / dev run.
//
//  WHAT THESE TESTS ARE *NOT* FOR:
//    Validating the real-world iPhone budgets in CLAUDE.md (≤20 min
//    end-to-end, ≤200 MB peak, etc). The simulator runs on the host
//    Mac's GPU/CPU and skips thermal throttling, so absolute numbers
//    here have NO relationship to on-device wall-clock. Device-budget
//    validation lives in Instruments on a real iPhone 13.
//
//  Baselines are recorded inline as a sim-only snapshot taken on
//  iPhone 17 sim (Apple Silicon host). If a CI run drifts >50% from
//  these, treat it as a regression hunt.
//

import AVFoundation
import XCTest
@testable import PlayerCut

final class PipelinePerformanceTests: XCTestCase {

    // Short fixture: 4 s of synthesized 1280×720 H.264. Stage 1 + Stage 2
    // do per-frame work, so a shorter source keeps each iteration under
    // 30 s on the simulator while still exercising the optical-flow
    // baseline window (5 s — see Stage1CoarseDetector.audioBaselineWindow).
    private var videoURL: URL!
    private var srcDuration: Double = 0

    override func setUp() async throws {
        try await super.setUp()
        var spec = SampleVideoFactory.Spec()
        spec.durationSeconds = 4
        videoURL = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        let asset = AVURLAsset(url: videoURL)
        srcDuration = try await asset.load(.duration).seconds
    }

    override func tearDown() async throws {
        if let url = videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makePlayer() -> PlayerEnrollment {
        PlayerEnrollment(
            id: UUID(), name: "Perf", jerseyNumber: "7",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
    }

    private func makeGame(player: PlayerEnrollment) -> GameSession {
        GameSession(
            id: UUID(), playerId: player.id, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: videoURL, audioLoudnessURL: videoURL,
            stage1Result: nil, stage2Result: nil,
            status: .awaitingProcessing, triggerSource: .manual,
            sceneType: .outdoor)
    }

    private func twoCandidateWindows() -> [CandidateWindow] {
        [
            CandidateWindow(id: UUID(), startTime: 0.5, endTime: 1.8,
                            audioScore: 0.7, motionScore: 0.6),
            CandidateWindow(id: UUID(), startTime: 2.0, endTime: 3.5,
                            audioScore: 0.55, motionScore: 0.5)
        ]
    }

    private func sixtySecondEditPlan(player: PlayerEnrollment,
                                     game: GameSession) async -> EditPlan {
        let selected = [
            makeSelectedClip(start: 0.4, end: 2.2, composite: 0.82),
            makeSelectedClip(start: 2.2, end: 3.8, composite: 0.70)
        ]
        let reelPlan = ReelPlan(selected: selected,
                                totalDuration: srcDuration, tier: .normal)
        let music = await MainActor.run {
            MusicLibrary.shared.pick(vibe: player.musicVibe,
                                     playerId: player.id,
                                     length: .sixtySeconds)
        }
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: srcDuration, profile: .highEnd)
        return builder.build(from: reelPlan, player: player, game: game,
                             musicURL: music?.url,
                             musicBPM: music.map { Double($0.bpm) })
    }

    private func makeSelectedClip(start: Double, end: Double,
                                  composite: Float) -> SelectedClip {
        let window = CandidateWindow(id: UUID(), startTime: start, endTime: end,
                                     audioScore: composite, motionScore: composite)
        let moment = ScoredMoment(
            id: UUID(), window: window,
            identificationConfidence: composite,
            activityScore: composite,
            playerBoundingBoxes: SampleVideoFactory.playerBoxes(start: start, end: end),
            compositeScore: composite)
        return SelectedClip(moment: moment, clipStart: start, clipEnd: end)
    }

    // MARK: - Async helper
    //
    // measure{} is synchronous. Bridge into async with a semaphore + Task.
    // Keeping the bridge here so each test reads as the timed operation
    // and nothing else.

    private func measureAsync(name: String,
                              iterations: Int = 3,
                              file: StaticString = #file,
                              line: UInt = #line,
                              block: @escaping () async throws -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        measure(options: options) {
            let sem = DispatchSemaphore(value: 0)
            var failure: Error?
            Task {
                do { try await block() } catch { failure = error }
                sem.signal()
            }
            sem.wait()
            if let failure {
                XCTFail("\(name) threw: \(failure)", file: file, line: line)
            }
        }
    }

    // MARK: - Stage 1
    //
    // Baseline (iPhone 17 sim, 4 s 1280×720 synthesized source,
    // recorded 2026-05-31): ~0.13 s / iteration, mean of 3.
    // The synthesized fixture has no real audio peaks above the
    // 2-sigma threshold and minimal inter-frame motion variance, so
    // most of the cost here is file open + loudness decode + the
    // early-exit checks. That is exactly the work most likely to
    // grow accidentally — a regression that double-decodes audio
    // or stops early-returning on degenerate inputs will land at
    // ≥0.25 s here.
    //
    // NOT a device-budget assertion — see file header.
    func testStage1CoarseDetectorPerformance() throws {
        let stage1 = Stage1CoarseDetector()
        let player = makePlayer()
        let game = makeGame(player: player)
        measureAsync(name: "Stage1.detect", iterations: 3) {
            _ = try await stage1.detect(in: game)
        }
    }

    // MARK: - Stage 2
    //
    // Baseline (iPhone 17 sim, 2 candidate windows of ~1.5 s each,
    // recorded 2026-05-31): ~0.15 s / iteration, mean of 3.
    // The synthesized fixture has no detectable persons, so most
    // windows produce no ScoredMoments and the cost is
    // VNDetectHumanRectangles + early-out. A regression that
    // re-enables full-res analysis (kills the 480-px downscale) or
    // drops the per-window skip-on-empty path will land at ≥0.5 s.
    func testStage2PlayerLocalizerPerformance() throws {
        let stage2 = Stage2PlayerLocalizer()
        let player = makePlayer()
        let game = makeGame(player: player)
        let candidates = twoCandidateWindows()
        measureAsync(name: "Stage2.localize", iterations: 3) {
            _ = try await stage2.localize(in: game,
                                          candidates: candidates,
                                          enrollment: player)
        }
    }

    // MARK: - ReelComposer
    //
    // Baseline (iPhone 17 sim, 2-clip 9:16 reel from a 4 s source,
    // recorded 2026-05-31): ~41.9 s / iteration, mean of 5
    // (41.95, 41.50, 41.47, 43.42, 41.39). This is the only stage
    // here that actually does meaningful work on the fixture — full
    // export through AVAssetExportSession + the MetalPetal custom
    // compositor + the music mix. A regression that re-introduces
    // software compositing or doubles a Metal pass will jump this
    // to ≥60 s.
    func testReelComposerPerformance() async throws {
        let player = makePlayer()
        let game = makeGame(player: player)
        let plan = await sixtySecondEditPlan(player: player, game: game)
        // Cache outputs across iterations so the measure block's only
        // moving variable is composer work, not directory creation.
        let composer = ReelComposer()
        composer.savesToPhotos = false
        measureAsync(name: "ReelComposer.compose", iterations: 5) {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("perf-reel-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try await composer.compose(plan: plan, game: game,
                                           player: player, outputURL: out)
        }
    }
}
