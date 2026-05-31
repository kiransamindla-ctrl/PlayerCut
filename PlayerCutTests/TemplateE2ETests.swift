//
//  TemplateE2ETests.swift
//  PlayerCutTests
//
//  End-to-end keystone export, parameterized over all 6 starting
//  ReelTemplates. Each test runs Stage 1 → ranker → EditPlanBuilder
//  (with the template) → ReelComposer → AVAssetExportSession and
//  asserts a playable 1080×1920 reel with audio + the requested
//  duration + at least one transition kind from the template's list.
//
//  Cost — each export takes 30–90 s on the sim, so the suite is
//  GATED on the env var ENABLE_TEMPLATE_E2E=1. The xcodebuild MCP's
//  100 s ceiling kills sweeps of all 6, so the gate keeps default
//  CI / dev runs green. To execute one for device validation:
//      ENABLE_TEMPLATE_E2E=1 xcodebuild test \
//          -only-testing:PlayerCutTests/TemplateE2ETests/test_beat_sync_fast \
//          -destination 'platform=iOS Simulator,name=iPhone 15'
//

import AVFoundation
import XCTest
@testable import PlayerCut

@MainActor
final class TemplateE2ETests: XCTestCase {

    // MARK: - One test method per template id — opt-in via env var.

    func test_beat_sync_fast()      async throws { try await runE2E(templateID: "beat-sync-fast") }
    func test_slowmo_cinematic()    async throws { try await runE2E(templateID: "slowmo-cinematic") }
    func test_minimal_vlog()        async throws { try await runE2E(templateID: "minimal-vlog") }
    func test_trendy_transitions()  async throws { try await runE2E(templateID: "trendy-transitions") }
    func test_attitude_montage()    async throws { try await runE2E(templateID: "attitude-montage") }
    func test_aesthetic_slow()      async throws { try await runE2E(templateID: "aesthetic-slow") }

    // MARK: - The body

    private func runE2E(templateID: String) async throws {
        guard ProcessInfo.processInfo.environment["ENABLE_TEMPLATE_E2E"] == "1" else {
            throw XCTSkip("TemplateE2E gated: export sweep would exceed xcodebuild MCP's 100 s ceiling. Re-run with ENABLE_TEMPLATE_E2E=1 to validate this template's full pipeline.")
        }
        let template = try XCTUnwrap(TemplateRegistry.shared.get(id: templateID),
                                     "Template \(templateID) not in registry")

        let spec = SampleVideoFactory.Spec()   // 8s, 1280x720, 30 fps
        let videoURL = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let player = makePlayer()
        let game = makeGame(playerID: player.id, videoURL: videoURL,
                            loudnessURL: videoURL)

        // Three clips: the highest-score one becomes the cold open, the
        // remaining two form the body — guarantees a body→body transition
        // that the template's transition policy can actually emit.
        let reelPlan = ReelPlan(
            selected: [
                makeSelectedClip(start: 0.5, end: 3.0, composite: 0.82),
                makeSelectedClip(start: 3.0, end: 5.5, composite: 0.70),
                makeSelectedClip(start: 5.5, end: 7.8, composite: 0.64),
            ],
            totalDuration: 8, tier: .normal)

        let music = MusicLibrary.shared.pick(
            vibe: template.musicVibe,
            playerId: player.id,
            length: .sixtySeconds)

        let settings = ReelSettings.defaults.applying(template)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 8,
            profile: .highEnd,
            settings: settings,
            template: template)
        let editPlan = builder.build(from: reelPlan,
                                     player: player,
                                     game: game,
                                     musicURL: music?.url,
                                     musicBPM: music.map { Double($0.bpm) })
        XCTAssertGreaterThan(editPlan.totalDuration, 0,
                             "[\(templateID)] EditPlan must have renderable duration")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(templateID)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let composer = ReelComposer()
        composer.savesToPhotos = false
        let result = try await composer.compose(
            plan: editPlan, game: game, player: player,
            outputURL: outputURL)

        // 1. File exists and is non-empty.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.localURL.path),
                      "[\(templateID)] export should produce a file")
        let size = (try FileManager.default
            .attributesOfItem(atPath: result.localURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        XCTAssertGreaterThan(size, 0,
                             "[\(templateID)] exported reel must be non-empty")

        // 2. Playable + 1080x1920.
        let out = AVURLAsset(url: result.localURL)
        let playable = try await out.load(.isPlayable)
        XCTAssertTrue(playable, "[\(templateID)] reel must be playable")
        let vtracks = try await out.loadTracks(withMediaType: .video)
        XCTAssertEqual(vtracks.count, 1, "[\(templateID)] one flattened video track")
        if let track = vtracks.first {
            let naturalSize = try await track.load(.naturalSize)
            XCTAssertEqual(abs(naturalSize.width), 1080, accuracy: 2,
                           "[\(templateID)] 1080-wide output")
            XCTAssertEqual(abs(naturalSize.height), 1920, accuracy: 2,
                           "[\(templateID)] 1920-tall output")
        }

        // 3. Audio track present (template's vibe drove the pick).
        let atracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertFalse(atracks.isEmpty,
                       "[\(templateID)] reel must carry music")

        // 4. Hero-at-position-0 (hook-first is on by default).
        if editPlan.body.count >= 2 {
            let maxEnergy = editPlan.body.map { $0.energy }.max() ?? 0
            XCTAssertEqual(editPlan.body[0].energy, maxEnergy, accuracy: 0.001,
                           "[\(templateID)] hook-first must place top-energy at index 0")
        }

        // 5. At least one body clip's transition kind appears in the
        //    template's transitions array. (.crossDissolve is used as
        //    the closing-card transition regardless, so we require a
        //    match somewhere in the body, not just the last one.)
        let bodyTransitions = Set(editPlan.body.map { $0.outgoingTransition })
        let templateTransitions = Set(template.transitions)
        let intersection = bodyTransitions.intersection(templateTransitions)
        XCTAssertFalse(intersection.isEmpty,
                       "[\(templateID)] no body transition matched the template's allowed set (body=\(bodyTransitions), template=\(templateTransitions))")
    }

    // MARK: - Test fixtures (copied from SampleVideoPipelineTests so each
    // file is independently runnable).

    private func makePlayer() -> PlayerEnrollment {
        PlayerEnrollment(
            id: UUID(),
            name: "TestKid", jerseyNumber: "11",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
    }

    private func makeGame(playerID: UUID,
                          videoURL: URL,
                          loudnessURL: URL) -> GameSession {
        GameSession(
            id: UUID(), playerId: playerID, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: videoURL, audioLoudnessURL: loudnessURL,
            stage1Result: nil, stage2Result: nil,
            status: .completed, triggerSource: .manual,
            sceneType: .outdoor)
    }

    private func makeSelectedClip(start: Double, end: Double,
                                  composite: Float) -> SelectedClip {
        let w = CandidateWindow(id: UUID(),
                                startTime: start, endTime: end,
                                audioScore: composite,
                                motionScore: composite)
        let m = ScoredMoment(id: UUID(), window: w,
                             identificationConfidence: composite,
                             activityScore: composite,
                             playerBoundingBoxes: [],
                             compositeScore: composite)
        return SelectedClip(moment: m, clipStart: start, clipEnd: end)
    }
}
