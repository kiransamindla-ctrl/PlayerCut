//
//  SampleVideoPipelineTests.swift
//  PlayerCutTests
//
//  Section 0 — the simulator-testable reel path. Feeds a synthesized
//  sample video (SampleVideoFactory) directly into the pipeline,
//  bypassing the camera, so the simulator can exercise:
//    - Stage 1 ingest + optical-flow analysis on a real file, and
//    - the full compose → export path (reframe/grade, speed ramps,
//      A/B transitions, music bed + ducking, AVAssetExportSession).
//
//  Before this test existed, CompositionTests carried the note:
//  "We can't actually invoke compose() without a fixture video." This
//  is that fixture, generated on the fly.
//

import AVFoundation
import XCTest
@testable import PlayerCut

final class SampleVideoPipelineTests: XCTestCase {

    // MARK: - Fixtures

    private func makePlayer() -> PlayerEnrollment {
        PlayerEnrollment(
            id: UUID(), name: "Sample Kid", jerseyNumber: "7",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
    }

    private func makeGame(playerID: UUID, videoURL: URL, loudnessURL: URL) -> GameSession {
        GameSession(
            id: UUID(), playerId: playerID, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: videoURL, audioLoudnessURL: loudnessURL,
            stage1Result: nil, stage2Result: nil,
            status: .awaitingProcessing, triggerSource: .manual,
            sceneType: .outdoor)
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

    // MARK: - Keystone: full compose → export on the simulator

    /// The full compose → export path runs against a real video file and
    /// produces a playable reel. Exercises Sections 1/2/4/5/6/7 in one
    /// shot: async ingest, the MetalPetal custom compositor (crop + LUT
    /// grade + overlays), speed ramps (scaleTimeRange), A/B transitions,
    /// the music-bed + ducking audio mix, and AVAssetExportSession with a
    /// custom AVVideoCompositing class. A corrupt composition would
    /// surface here as -11841 ("Operation Stopped") or an unplayable file.
    func testComposeExportsPlayableReelFromSampleVideo() async throws {
        let spec = SampleVideoFactory.Spec()         // 8 s, 1280×720, 30 fps
        let videoURL = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // The synthesized source must itself be real + playable before we
        // lean on it as a fixture.
        let srcAsset = AVURLAsset(url: videoURL)
        let srcDuration = try await srcAsset.load(.duration).seconds
        XCTAssertEqual(srcDuration, spec.durationSeconds, accuracy: 0.34,
                       "Synthesized source duration should match the spec")
        let srcPlayable = try await srcAsset.load(.isPlayable)
        XCTAssertTrue(srcPlayable, "Synthesized sample video must be playable")

        let player = makePlayer()
        let game = makeGame(playerID: player.id, videoURL: videoURL,
                            loudnessURL: videoURL)   // loudness unused on this path

        // Three clips: the highest-energy one becomes the cold open, the
        // remaining two form the body — which guarantees at least one
        // real body→body A/B transition (Section 5).
        let reelPlan = ReelPlan(
            selected: [
                makeSelectedClip(start: 0.5, end: 3.0, composite: 0.82),
                makeSelectedClip(start: 3.0, end: 5.5, composite: 0.70),
                makeSelectedClip(start: 5.5, end: 7.8, composite: 0.64)
            ],
            totalDuration: srcDuration, tier: .normal)

        // Real bundled music so the music-bed + ducking + closing-fade
        // audio mix (Section 6) runs against an actual audio asset and
        // the output carries an audio track of matching duration.
        let music = await MainActor.run {
            MusicLibrary.shared.pick(vibe: player.musicVibe,
                                     playerId: player.id, length: .sixtySeconds)
        }
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: srcDuration, profile: .highEnd)
        let editPlan = builder.build(from: reelPlan, player: player, game: game,
                                     musicURL: music?.url,
                                     musicBPM: music.map { Double($0.bpm) })
        XCTAssertGreaterThan(editPlan.totalDuration, 0,
                             "EditPlan must have renderable duration")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("playercut-reel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let composer = ReelComposer()
        composer.savesToPhotos = false   // seam: don't block on Photos auth in the test host

        let result = try await composer.compose(plan: editPlan, game: game,
                                                player: player, outputURL: outputURL)

        // 1. The export produced a real, non-empty file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.localURL.path),
                      "Exported reel file should exist")
        let size = (try FileManager.default
            .attributesOfItem(atPath: result.localURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        XCTAssertGreaterThan(size, 0, "Exported reel must be non-empty")

        // 2. The file is playable — i.e. the composition was valid (no
        //    -11841) and the writer flushed a complete movie atom.
        let out = AVURLAsset(url: result.localURL)
        let playable = try await out.load(.isPlayable)
        XCTAssertTrue(playable, "Exported reel must be playable")

        // 3. Output shape: one flattened video track, plus the music bed.
        let vtracks = try await out.loadTracks(withMediaType: .video)
        XCTAssertEqual(vtracks.count, 1, "Export flattens to a single output video track")
        let atracks = try await out.loadTracks(withMediaType: .audio)
        XCTAssertFalse(atracks.isEmpty,
                       "Reel should carry the music-bed audio track (Section 6)")

        // 4. Duration matches the plan within a second (beat-snap + ramp
        //    rounding accounts for the slack).
        let outDuration = try await out.load(.duration).seconds
        XCTAssertEqual(outDuration, editPlan.totalDuration, accuracy: 1.0,
                       "Reel duration should track the plan")

        // 5. Output frame size is the requested 9:16 render size.
        if let track = vtracks.first {
            let naturalSize = try await track.load(.naturalSize)
            XCTAssertEqual(abs(naturalSize.width), 1080, accuracy: 2)
            XCTAssertEqual(abs(naturalSize.height), 1920, accuracy: 2)
        }

        // 6. We never silently fell back to a primitive concat.
        let snap = await DiagnosticsStore.shared.currentSnapshot()
        XCTAssertNotEqual(snap.counters[CounterKey.composerUsedFallback.rawValue], 1,
                          "Composer must not report a primitive fallback")
    }

    // MARK: - Stage 1 ingest + optical flow on the simulator

    /// Stage 1 runs end-to-end on the synthesized video. Production writes
    /// an empty loudness sidecar under UIImagePicker capture
    /// (DeviceCapabilities.LoudnessSample doc) and leans on optical flow,
    /// so we mirror that exactly. Per the never-reject contract an empty
    /// candidate list is a VALID result; the assertion is that the
    /// detector COMPLETES (does not throw) and reports a duration.
    func testStage1RunsOnSampleVideo() async throws {
        let videoURL = try await SampleVideoFactory.makeSampleVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let loudnessURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("playercut-loudness-\(UUID().uuidString).json")
        try Data("[]".utf8).write(to: loudnessURL)
        defer { try? FileManager.default.removeItem(at: loudnessURL) }

        let player = makePlayer()
        let game = makeGame(playerID: player.id, videoURL: videoURL,
                            loudnessURL: loudnessURL)

        let stage1 = Stage1CoarseDetector()
        let result = try await stage1.detect(in: game)

        XCTAssertGreaterThanOrEqual(result.processingDuration, 0,
                                    "Stage 1 should report a processing duration")
        XCTAssertLessThanOrEqual(result.candidates.count, 80,
                                 "Stage 1 caps candidates at maxCandidates")
    }
}
