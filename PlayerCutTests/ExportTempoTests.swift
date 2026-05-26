//
//  ExportTempoTests.swift
//  PlayerCutTests
//
//  Section 1 — the export regression net. Export died with -11841
//  "Operation Stopped" at 140 BPM × 10 clips when beat-snap trimmed a clip
//  too short or broke instruction tiling. Two layers of proof:
//
//   1. FAST, all 20 bundled tempos: the beat-snap floor never yields a
//      sub-minimum clip at ANY bundled BPM (the layer where the bug
//      originates), checked on a 10-clip plan.
//   2. REAL export at the tempo extremes (slowest / mid / fastest bundled
//      BPM) with a 10-clip plan — the validator + AVAssetExportSession
//      produce a playable 1080×1920 reel even at the worst case.
//

import AVFoundation
import XCTest
@testable import PlayerCut

final class ExportTempoTests: XCTestCase {

    private func player() -> PlayerEnrollment {
        PlayerEnrollment(
            id: UUID(), name: "Tempo", jerseyNumber: "1",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
    }

    private func game(_ p: PlayerEnrollment, _ url: URL) -> GameSession {
        GameSession(id: UUID(), playerId: p.id, sport: .soccer,
                    startedAt: Date(), endedAt: Date(),
                    rawVideoURL: url, audioLoudnessURL: url,
                    stage1Result: nil, stage2Result: nil,
                    status: .completed, triggerSource: .manual, sceneType: .outdoor)
    }

    /// `count` clips packed into `[0.2, sourceDuration-0.3]`, each `clipLen`
    /// long, with real (moving) boxes — a dense plan that stresses tiling.
    private func tenClipPlan(sourceDuration: Double, clipLen: Double,
                             count: Int = 10) -> ReelPlan {
        let span = (sourceDuration - 0.5)
        let step = span / Double(count)
        let clips: [SelectedClip] = (0..<count).map { i in
            let s = 0.2 + Double(i) * step
            let e = min(sourceDuration - 0.1, s + clipLen)
            let composite: Float = (i == 0 ? 0.85 : 0.66)   // first → cold open
            let w = CandidateWindow(id: UUID(), startTime: s, endTime: e,
                                    audioScore: composite, motionScore: composite)
            let m = ScoredMoment(id: UUID(), window: w,
                                 identificationConfidence: composite,
                                 activityScore: composite,
                                 playerBoundingBoxes: SampleVideoFactory.playerBoxes(start: s, end: e),
                                 compositeScore: composite)
            return SelectedClip(moment: m, clipStart: s, clipEnd: e)
        }
        return ReelPlan(selected: clips, totalDuration: sourceDuration, tier: .normal)
    }

    private func editPlan(_ reel: ReelPlan, bpm: Double,
                          player: PlayerEnrollment, game: GameSession,
                          sourceDuration: Double, musicURL: URL? = nil) -> EditPlan {
        EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: sourceDuration, profile: .highEnd)
        .build(from: reel, player: player, game: game,
               musicURL: musicURL, musicBPM: bpm)
    }

    // MARK: - 1. Beat-snap floor holds at all 20 bundled tempos (fast)

    @MainActor
    func testBeatSnapFloorHoldsAtAllBundledBPMs() {
        let bpms = MusicLibrary.shared.allTracks.map { Double($0.bpm) }
        XCTAssertEqual(bpms.count, 20, "Expected 20 bundled tracks")
        let p = player()
        let g = game(p, URL(fileURLWithPath: "/tmp/x.mov"))

        for bpm in bpms {
            let plan = editPlan(tenClipPlan(sourceDuration: 60, clipLen: 4.0),
                                bpm: bpm, player: p, game: g, sourceDuration: 60)
            let clips = [plan.coldOpen].compactMap { $0 } + plan.body
            XCTAssertFalse(clips.isEmpty, "bpm \(bpm): plan should have clips")
            for (i, c) in clips.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    c.renderedDuration, 0.5,
                    "bpm \(bpm) clip \(i): rendered \(c.renderedDuration)s below the export-safe floor")
                XCTAssertGreaterThan(c.sourceDuration, 0,
                                     "bpm \(bpm) clip \(i): non-positive source")
            }
            XCTAssertGreaterThan(plan.totalDuration, 0)
        }
    }

    // MARK: - 2. Real export at the tempo extremes (the reported failure)

    func testExportSurvivesTenClipsAtTempoExtremes() async throws {
        let sourceDuration = 8.0
        let videoURL = try await SampleVideoFactory.makeSampleVideo(
            spec: .init(durationSeconds: sourceDuration))
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let p = player()
        let g = game(p, videoURL)
        // Real bundled music for the audio bed (matches the production path);
        // the target BPM below drives beat-snap independently.
        let musicURL = await MainActor.run {
            MusicLibrary.shared.pick(vibe: .energetic, playerId: p.id,
                                     length: .sixtySeconds)?.url
        }

        // Slowest, mid, and fastest bundled tempos. 142 covers the reported
        // 140-BPM × 10-clip failure; 10 clips in 8 s ≈ 0.6 s each forces
        // beat-snap to floor.
        for bpm in [78.0, 117.0, 142.0] {
            let plan = editPlan(tenClipPlan(sourceDuration: sourceDuration, clipLen: 0.6),
                                bpm: bpm, player: p, game: g,
                                sourceDuration: sourceDuration, musicURL: musicURL)
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tempo-\(Int(bpm))-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: outURL) }

            let composer = ReelComposer()
            composer.savesToPhotos = false
            let result = try await composer.compose(plan: plan, game: g,
                                                     player: p, outputURL: outURL)

            let out = AVURLAsset(url: result.localURL)
            let playable = try await out.load(.isPlayable)
            XCTAssertTrue(playable, "bpm \(bpm): reel must be playable (no -11841)")
            let vtracks = try await out.loadTracks(withMediaType: .video)
            if let t = vtracks.first {
                let sz = try await t.load(.naturalSize)
                XCTAssertEqual(abs(sz.width), 1080, accuracy: 2, "bpm \(bpm) width")
                XCTAssertEqual(abs(sz.height), 1920, accuracy: 2, "bpm \(bpm) height")
            }
            // The validator must have produced exact contiguous tiling.
            let asm = try XCTUnwrap(composer.lastAssembled)
            let instr = asm.videoComposition.instructions
            XCTAssertEqual(instr.first!.timeRange.start.seconds, 0, accuracy: 0.001,
                           "bpm \(bpm): first instruction starts at .zero")
            for i in 1..<instr.count {
                XCTAssertEqual(instr[i].timeRange.start.seconds,
                               instr[i - 1].timeRange.end.seconds, accuracy: 0.001,
                               "bpm \(bpm): instructions must tile contiguously")
            }
            XCTAssertEqual(instr.last!.timeRange.end.seconds,
                           asm.totalDuration.seconds, accuracy: 0.02,
                           "bpm \(bpm): tiling must cover the full composition")
        }
    }
}
