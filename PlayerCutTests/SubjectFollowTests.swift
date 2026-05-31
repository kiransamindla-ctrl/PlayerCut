//
//  SubjectFollowTests.swift
//  PlayerCutTests
//
//  Stage 4 proof. The sample video draws a moving rectangle, not a human,
//  so VNDetectHumanRectanglesRequest can't pick it up — the real Stage 2
//  detection path is device-only. What IS provable on the simulator, and
//  is the actual Stage 4 logic, splits in two:
//
//   1. SUBJECT SELECTION — given persistent ByteTracker tracks, pick the
//      enrolled player's track (identity) or a dominant central mover
//      (fallback), and follow THAT track. Proven here with synthetic
//      detections fed through the real ByteTracker.
//   2. FOLLOW-SUBJECT REFRAME — the crop center tracks the selected
//      track's moving box rather than sitting static. Proven here against
//      the real EditPlanBuilder crop-keyframe output.
//

import CoreGraphics
import XCTest
@testable import PlayerCut

final class SubjectTrackSelectorTests: XCTestCase {

    /// Feed synthetic detections through the real ByteTracker: a moving
    /// "enrolled" subject (high identity) plus two off-center distractors
    /// (low identity). The selector must pick the subject's track AND its
    /// boxes must follow the subject's left→right motion.
    func testSelectsIdentifiedMovingSubjectOverDistractors() {
        let tracker = ByteTracker()
        let frames = 12
        for i in 0..<frames {
            let t = Double(i) * (1.0 / 6.0)
            let f = CGFloat(i) / CGFloat(frames - 1)
            // Enrolled subject: box slides 0.20 → 0.60 in x, high identity.
            let subject = ByteDetection(
                frameTime: t,
                box: CGRect(x: 0.20 + 0.40 * f, y: 0.45, width: 0.15, height: 0.30),
                confidence: 0.9,
                identityScore: 0.82)
            // Distractor A: static top-right, low identity.
            let distA = ByteDetection(
                frameTime: t,
                box: CGRect(x: 0.80, y: 0.05, width: 0.10, height: 0.20),
                confidence: 0.9, identityScore: 0.10)
            // Distractor B: static bottom-left, low identity.
            let distB = ByteDetection(
                frameTime: t,
                box: CGRect(x: 0.03, y: 0.72, width: 0.10, height: 0.20),
                confidence: 0.9, identityScore: 0.08)
            tracker.step(detections: [subject, distA, distB])
        }

        let selection = SubjectTrackSelector()
            .select(from: tracker.tracks, analyzedFrameCount: frames)
        let sel = try! XCTUnwrap(selection, "A subject track must be selected")

        XCTAssertTrue(sel.identified, "High-identity track should be chosen by identity")
        XCTAssertGreaterThanOrEqual(sel.meanIdentity, 0.55,
                                    "Selected track's mean identity clears the threshold")

        // The selected track must be the moving subject and its boxes must
        // FOLLOW it (not a static distractor).
        let centers = sel.track.centroidPath.map(\.point)
        XCTAssertGreaterThanOrEqual(centers.count, 3)
        let firstX = centers.first!.x
        let lastX = centers.last!.x
        XCTAssertGreaterThan(lastX - firstX, 0.20,
                             "Selected track's center should travel left→right with the subject")
        XCTAssertEqual(firstX, 0.20 + 0.075, accuracy: 0.06,
                       "Track should start where the subject started (≈0.275 midX)")
    }

    /// No identity match anywhere → the selector falls back to the
    /// dominant central mover (not a static off-center figure), marked
    /// identified == false so the ranker scores it on motion.
    func testFallsBackToCentralMoverWhenNoIdentity() {
        let tracker = ByteTracker()
        let frames = 12
        for i in 0..<frames {
            let t = Double(i) * (1.0 / 6.0)
            let f = CGFloat(i) / CGFloat(frames - 1)
            // Central mover, LOW identity (can't be positively ID'd).
            let mover = ByteDetection(
                frameTime: t,
                box: CGRect(x: 0.38 + 0.12 * f, y: 0.42, width: 0.15, height: 0.30),
                confidence: 0.9, identityScore: 0.12)
            // Static off-center distractor, also low identity.
            let corner = ByteDetection(
                frameTime: t,
                box: CGRect(x: 0.82, y: 0.05, width: 0.10, height: 0.20),
                confidence: 0.9, identityScore: 0.10)
            tracker.step(detections: [mover, corner])
        }

        let selection = SubjectTrackSelector()
            .select(from: tracker.tracks, analyzedFrameCount: frames)
        let sel = try! XCTUnwrap(selection, "Fallback should still select a subject")

        XCTAssertFalse(sel.identified, "No identity match → fallback path")
        let centers = sel.track.centroidPath.map(\.point)
        // The central mover sits near x≈0.45–0.57; the corner is at 0.87.
        let meanX = centers.map(\.x).reduce(0, +) / CGFloat(centers.count)
        XCTAssertLessThan(meanX, 0.7,
                          "Fallback must pick the central mover, not the corner figure")
        XCTAssertGreaterThan(SubjectTrackSelector.motion(sel.track), 0,
                             "Fallback subject should actually be moving")
    }

    /// A field of only fleeting/sparse detections (no track reaches the
    /// minimum length) yields no selection → caller Ken-Burns via Tier 3.
    func testNoPersistentTrackYieldsNoSelection() {
        let tracker = ByteTracker()
        // Two frames only, boxes that don't overlap frame-to-frame → no
        // track reaches minDetections (3).
        tracker.step(detections: [ByteDetection(
            frameTime: 0, box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.2),
            confidence: 0.9, identityScore: 0.9)])
        tracker.step(detections: [ByteDetection(
            frameTime: 0.2, box: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.2),
            confidence: 0.9, identityScore: 0.9)])
        let selection = SubjectTrackSelector()
            .select(from: tracker.tracks, analyzedFrameCount: 2)
        XCTAssertNil(selection, "No persistent track → no subject → Ken Burns fallback")
    }
}

// MARK: - Follow-subject reframe

final class FollowSubjectReframeTests: XCTestCase {

    private func makePlayer() -> PlayerEnrollment {
        PlayerEnrollment(
            id: UUID(), name: "Mover", jerseyNumber: "9",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
    }

    private func makeGame(playerID: UUID) -> GameSession {
        GameSession(
            id: UUID(), playerId: playerID, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: URL(fileURLWithPath: "/tmp/x.mov"),
            audioLoudnessURL: URL(fileURLWithPath: "/tmp/x.json"),
            stage1Result: nil, stage2Result: nil,
            status: .completed, triggerSource: .manual, sceneType: .outdoor)
    }

    private func clip(start: Double, end: Double, composite: Float) -> SelectedClip {
        let window = CandidateWindow(id: UUID(), startTime: start, endTime: end,
                                     audioScore: composite, motionScore: composite)
        let moment = ScoredMoment(
            id: UUID(), window: window,
            identificationConfidence: composite, activityScore: composite,
            playerBoundingBoxes: SampleVideoFactory.playerBoxes(start: start, end: end),
            compositeScore: composite)
        return SelectedClip(moment: moment, clipStart: start, clipEnd: end)
    }

    /// The crop center must FOLLOW the moving subject, not sit static. The
    /// subject (SampleVideoFactory.playerBoxes) travels left→right, so the
    /// reframe crop center's x must travel a meaningful distance and trend
    /// in the same direction across the clip.
    func testReframeCropFollowsMovingSubject() {
        let player = makePlayer()
        let game = makeGame(playerID: player.id)
        // Two clips: the higher-energy one becomes the cold open; the
        // other becomes a body clip whose crop keyframes we inspect.
        let plan = ReelPlan(
            selected: [clip(start: 0.0, end: 2.0, composite: 0.85),
                       clip(start: 2.0, end: 6.0, composite: 0.62)],
            totalDuration: 6, tier: .normal)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 8, profile: .highEnd)
        let edit = builder.build(from: plan, player: player, game: game,
                                 musicURL: nil, musicBPM: 140)

        let body = try! XCTUnwrap(edit.body.first ?? edit.coldOpen,
                                  "Plan should yield a renderable clip")
        let xs = body.cropKeyframes.map { $0.center.x }
        XCTAssertGreaterThanOrEqual(xs.count, 2)

        let span = xs.max()! - xs.min()!
        XCTAssertGreaterThan(span, 0.08,
                             "Crop center must MOVE — a static center means the reframe isn't following the subject")
        XCTAssertGreaterThan(xs.last! - xs.first!, 0.05,
                             "Crop center should trend left→right with the subject's motion")

        // And it must stay in-bounds (no out-of-frame black).
        for kf in body.cropKeyframes {
            XCTAssertGreaterThanOrEqual(kf.center.x, 0)
            XCTAssertLessThanOrEqual(kf.center.x, 1)
            XCTAssertGreaterThanOrEqual(kf.center.y, 0)
            XCTAssertLessThanOrEqual(kf.center.y, 1)
        }
    }

    /// No subject boxes → Ken Burns (a deliberate, bounded camera move),
    /// not a crash and not a frozen frame.
    func testNoSubjectFallsBackToKenBurns() {
        let player = makePlayer()
        let game = makeGame(playerID: player.id)
        let window = CandidateWindow(id: UUID(), startTime: 0, endTime: 3,
                                     audioScore: 0.5, motionScore: 0.5)
        let moment = ScoredMoment(id: UUID(), window: window,
                                  identificationConfidence: 0.5, activityScore: 0.5,
                                  playerBoundingBoxes: [],  // no subject
                                  compositeScore: 0.5)
        let plan = ReelPlan(selected: [SelectedClip(moment: moment, clipStart: 0, clipEnd: 3)],
                            totalDuration: 3, tier: .montageFallback)
        let builder = EditPlanBuilder(
            style: .chill,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 8, profile: .highEnd)
        let edit = builder.build(from: plan, player: player, game: game,
                                 musicURL: nil, musicBPM: 90)
        let c = try! XCTUnwrap(edit.body.first ?? edit.coldOpen)
        XCTAssertFalse(c.cropKeyframes.isEmpty, "Ken Burns must still emit keyframes")
        for kf in c.cropKeyframes {
            XCTAssertGreaterThanOrEqual(kf.scale, 1.0, "Ken Burns scale never starves the crop")
        }
    }
}
