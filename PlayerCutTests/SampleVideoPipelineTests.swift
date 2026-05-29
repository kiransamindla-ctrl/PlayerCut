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

        // 7. White-box -11841-avoidance invariants (Section 8), asserted
        //    against the exact composition that just exported cleanly.
        //
        //    NOTE: for a MULTI-instruction custom video composition the
        //    correct invariant is contiguous, non-overlapping tiling from
        //    .zero to totalDuration — NOT each instruction spanning the
        //    whole composition (that rule applies to single- or
        //    layer-instruction setups). Tiling with a gap or overlap is
        //    what actually triggers -11841 "Operation Stopped" here.
        let assembled = try XCTUnwrap(composer.lastAssembled,
                                      "compose() should have snapshotted the assembly")

        // ≤ 2 video tracks (A/B). >15-16 tracks fails export.
        let videoTracks = assembled.composition.tracks(withMediaType: .video)
        XCTAssertLessThanOrEqual(videoTracks.count, 2,
                                 "Composition must cap video tracks at 2 (A/B)")

        let instr = assembled.videoComposition.instructions
        XCTAssertFalse(instr.isEmpty, "Composition must have at least one instruction")
        XCTAssertEqual(instr.first!.timeRange.start.seconds, 0, accuracy: 0.001,
                       "First instruction must start at .zero")
        for i in 1..<instr.count {
            XCTAssertEqual(instr[i].timeRange.start.seconds,
                           instr[i - 1].timeRange.end.seconds, accuracy: 0.002,
                           "Instructions must tile contiguously (no gaps/overlaps)")
        }
        XCTAssertEqual(instr.last!.timeRange.end.seconds,
                       assembled.totalDuration.seconds, accuracy: 0.05,
                       "Instructions must cover the full composition duration")
        for ins in instr {
            XCTAssertGreaterThan(ins.timeRange.duration.seconds, 0,
                                 "No instruction may have non-positive duration")
            XCTAssertLessThanOrEqual(ins.timeRange.end.seconds,
                                     assembled.totalDuration.seconds + 0.05,
                                     "No instruction may extend past the composition")
        }

        // A/V invariant (-11841 guard): NO audio track may exceed the video
        // timeline. Shorter is fine — the title and closing cards are
        // silent overlays, so the game-audio track legitimately has gaps;
        // the pre-export validator inserts empty padding that the export
        // honors even though AVMutableCompositionTrack.timeRange only
        // reports the media-bearing extent. We additionally assert that AT
        // LEAST ONE audio track spans the full reel (the music bed) so the
        // reel doesn't end in silence before the closing card finishes.
        for at in assembled.composition.tracks(withMediaType: .audio)
        where at.timeRange.duration.seconds > 0 {
            XCTAssertLessThanOrEqual(at.timeRange.duration.seconds,
                                     assembled.totalDuration.seconds + 0.05,
                                     "Audio track must not exceed video timeline (-11841 trigger)")
        }
        let hasFullAudioCoverage = assembled.composition
            .tracks(withMediaType: .audio)
            .contains {
                abs($0.timeRange.duration.seconds - assembled.totalDuration.seconds) < 0.1
            }
        XCTAssertTrue(hasFullAudioCoverage,
                      "At least one audio track (the music bed) should span the full reel")

        // 8. Per-stage proof that the right things actually happened on the
        //    sample-video reel — not just that a file came out.

        // Stage 8 — speed ramps: an energetic, high-energy plan must carry
        // at least one slow-mo segment (factor < 1).
        let allClips = [editPlan.coldOpen].compactMap { $0 } + editPlan.body
        let hasRamp = allClips.contains { clip in
            clip.speedCurve.segments.contains { $0.factor < 0.99 }
        }
        XCTAssertTrue(hasRamp,
                      "Stage 8: an energetic high-energy plan must include a slow-mo ramp")

        // Stage 9 — transitions: at least one instruction blends across the
        // 2-track A/B boundary.
        let transitions = assembled.instructions.filter { $0.transitionKind != nil }
        XCTAssertFalse(transitions.isEmpty,
                       "Stage 9: reel must have ≥1 A/B transition")
        XCTAssertEqual(videoTracks.count, 2,
                       "Stage 9: A/B two-track structure must be present to blend")

        // Stage 10 — audio mix: music + game-audio input parameters wired
        // (the duck/fade envelopes ride on these; no-op-safe at 0 loudness).
        XCTAssertFalse(assembled.audioMix.inputParameters.isEmpty,
                       "Stage 10: audio mix must carry input parameters (music bed + ducking)")

        // Stage 11 — export codec at 1080×1920. On the simulator HEVC may
        // fall back to H.264; accept either and log which.
        if let track = vtracks.first {
            let formats = try await track.load(.formatDescriptions)
            if let fmt = formats.first {
                let sub = CMFormatDescriptionGetMediaSubType(fmt)
                let known: Set<FourCharCode> = [kCMVideoCodecType_HEVC,
                                                kCMVideoCodecType_H264]
                XCTAssertTrue(known.contains(sub),
                              "Stage 11: output should be HEVC or H.264 (got \(sub))")
            }
        }
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
