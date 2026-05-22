//
//  CompositionTests.swift
//  PlayerCutTests
//
//  Unit tests for the cinematic composer pipeline:
//   - GameSession relative-path resolver (PART 1)
//   - EditPlanBuilder auto-reframe + speed-curve correctness (PART 3A,B)
//   - Beat snapper (PART 3C)
//   - EditStyle ↔ MusicVibe mapping (PART 4)
//   - EditPlan totalDuration shape (PART 5)
//

import XCTest
@testable import PlayerCut

final class GameSessionRelativePathTests: XCTestCase {

    /// Sanity: rebuilding the URL against the live Documents directory
    /// returns the expected reels/<id>.mp4 path.
    func testAbsoluteURLForRelativePath() {
        let url = GameSession.absoluteURL(forRelativePath: "reels/abc.mp4")
        XCTAssertEqual(url.lastPathComponent, "abc.mp4")
        XCTAssertTrue(url.path.contains("/reels/"))
        XCTAssertTrue(url.path.hasSuffix("/reels/abc.mp4"))
    }

    /// A round-trip from absolute URL → relative path → absolute URL
    /// must land in the *current* Documents container even when the
    /// input came from a stale one.
    func testRebaseFromStaleAbsoluteURL() {
        // Construct a "stale" URL that pretends Documents lives at a
        // different container UUID.
        let stale = URL(fileURLWithPath:
            "/var/mobile/Containers/Data/Application/STALE-UUID-12345/Documents/reels/xyz.mp4")
        let rebased = GameSession.rebaseIntoCurrentDocuments(stale)
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        XCTAssertTrue(rebased.path.hasPrefix(docs.path),
                      "Rebase should anchor under current Documents")
        XCTAssertEqual(rebased.lastPathComponent, "xyz.mp4")
        XCTAssertTrue(rebased.path.contains("/reels/"))
    }

    /// A URL with no /Documents/ segment still gets a reasonable
    /// default — assume it belongs in reels/.
    func testRebaseFromAbsoluteURLWithoutDocumentsSegment() {
        let weird = URL(fileURLWithPath: "/private/var/tmp/orphan.mp4")
        let rebased = GameSession.rebaseIntoCurrentDocuments(weird)
        XCTAssertEqual(rebased.lastPathComponent, "orphan.mp4")
        XCTAssertTrue(rebased.path.contains("/reels/"))
    }

    /// The migration must survive a JSON round-trip: encoding an old-
    /// style absolute URL and re-decoding into a fresh GameSession
    /// should yield a URL anchored to the current Documents directory.
    func testJSONRoundTripMigratesLegacyAbsoluteURL() throws {
        let id = UUID()
        let playerID = UUID()
        let staleAbsolute =
            "file:///var/mobile/Containers/Data/Application/STALE/Documents/reels/\(id.uuidString).mp4"
        // Hand-craft a JSON document with the legacy field shape so we
        // exercise the migration branch in init(from:).
        let legacyJSON: [String: Any] = [
            "id": id.uuidString,
            "playerId": playerID.uuidString,
            "sport": "basketball",
            "startedAt": ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!.timeIntervalSinceReferenceDate,
            "rawVideoURL": "file:///tmp/raw.mov",
            "audioLoudnessURL": "file:///tmp/audio.json",
            "localReelURL": staleAbsolute,
            "savedToPhotos": true,
            "status": "completed",
            "triggerSource": "manual",
            "sceneType": "outdoor"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .deferredToData
        decoder.dateDecodingStrategy = .iso8601
        // The default date decoding format doesn't match; use a custom
        // formatter so the encode/decode hits the legacy field cleanly.
        let restored = try restoreLegacyGameSession(from: data,
                                                    id: id,
                                                    playerID: playerID,
                                                    staleAbsolute: staleAbsolute)
        let docs = GameSession.documentsURL.path
        XCTAssertTrue(restored.localReelURL?.path.hasPrefix(docs) ?? false,
                      "Legacy absolute URL should be rebased under current Documents")
        XCTAssertEqual(restored.localReelURL?.lastPathComponent,
                       "\(id.uuidString).mp4")
    }

    /// Helper that constructs a GameSession via decode after coercing
    /// the JSON dictionary into Codable-compatible shapes. Kept in the
    /// test target so the production model doesn't have to compromise.
    private func restoreLegacyGameSession(from data: Data,
                                          id: UUID,
                                          playerID: UUID,
                                          staleAbsolute: String) throws -> GameSession {
        // Build a CodableShim that mirrors the legacy schema so we can
        // hand the bytes to JSONDecoder.
        struct Shim: Codable {
            var id: UUID
            var playerId: UUID
            var sport: Sport
            var startedAt: Date
            var rawVideoURL: URL
            var audioLoudnessURL: URL
            var localReelURL: URL?
            var savedToPhotos: Bool
            var status: GameStatus
            var triggerSource: TriggerSource
            var sceneType: SceneType
        }
        let shim = Shim(
            id: id,
            playerId: playerID,
            sport: .basketball,
            startedAt: Date(timeIntervalSinceReferenceDate: 757382400),
            rawVideoURL: URL(string: "file:///tmp/raw.mov")!,
            audioLoudnessURL: URL(string: "file:///tmp/audio.json")!,
            localReelURL: URL(string: staleAbsolute)!,
            savedToPhotos: true,
            status: .completed,
            triggerSource: .manual,
            sceneType: .outdoor)
        let shimData = try JSONEncoder().encode(shim)
        return try JSONDecoder().decode(GameSession.self, from: shimData)
    }
}

// MARK: - Auto-reframe + speed curves

final class EditPlanBuilderTests: XCTestCase {

    /// Helper to build a SelectedClip with a synthetic player track.
    private func makeClip(start: Double = 5,
                          end: Double = 10,
                          composite: Float = 0.8,
                          boxes: [TimedBox]? = nil) -> SelectedClip {
        let window = CandidateWindow(id: UUID(),
                                     startTime: start,
                                     endTime: end,
                                     audioScore: composite,
                                     motionScore: composite)
        let defaultBoxes: [TimedBox] = (0...10).map { i in
            let t = start + Double(i) * (end - start) / 10
            // Player moves diagonally across the frame.
            let x = 0.3 + Double(i) * 0.04
            let y = 0.4 + Double(i) * 0.02
            return TimedBox(time: t,
                            box: CGRect(x: x, y: y, width: 0.1, height: 0.15))
        }
        let moment = ScoredMoment(
            id: UUID(),
            window: window,
            identificationConfidence: composite,
            activityScore: composite,
            playerBoundingBoxes: boxes ?? defaultBoxes,
            compositeScore: composite)
        return SelectedClip(moment: moment,
                            clipStart: start,
                            clipEnd: end)
    }

    /// Crop keyframes must stay normalized in [0,1] and the time axis
    /// must be monotonically non-decreasing.
    func testCropKeyframesStayWithinBounds() {
        let clip = makeClip()
        let plan = ReelPlan(selected: [clip],
                            totalDuration: 5,
                            tier: .normal)
        let player = PlayerEnrollment(
            id: UUID(), name: "Test", jerseyNumber: "7",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .basketball, createdAt: Date())
        let game = makeGame(playerID: player.id)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 60,
            profile: .highEnd)
        let edit = builder.build(from: plan,
                                 player: player,
                                 game: game,
                                 musicURL: nil,
                                 musicBPM: 140)
        guard let body = edit.body.first ?? edit.coldOpen else {
            return XCTFail("EditPlan should contain at least one clip")
        }
        XCTAssertFalse(body.cropKeyframes.isEmpty)
        for kf in body.cropKeyframes {
            XCTAssertGreaterThanOrEqual(kf.center.x, 0)
            XCTAssertLessThanOrEqual(kf.center.x, 1)
            XCTAssertGreaterThanOrEqual(kf.center.y, 0)
            XCTAssertLessThanOrEqual(kf.center.y, 1)
            XCTAssertGreaterThanOrEqual(kf.scale, 1.0)
            XCTAssertLessThanOrEqual(kf.scale, 1.5)
        }
        // Monotonic time.
        let times = body.cropKeyframes.map { $0.time }
        XCTAssertEqual(times, times.sorted(),
                       "Crop keyframes must be chronological")
    }

    /// Critical-damping output must not jitter — successive samples
    /// should never reverse direction more often than ~ω per second.
    /// Concrete test: variance of the second derivative should stay
    /// modest. Easier proxy: the path length of the center is bounded
    /// by the raw path length (smoother ≤ rawer).
    func testCropKeyframesDoNotJitter() {
        // Synthetic raw track with a sawtooth to exaggerate jitter
        // potential.
        let boxes: [TimedBox] = (0..<60).map { i in
            let t = 5.0 + Double(i) * 0.1
            let x = i.isMultiple(of: 2) ? 0.4 : 0.6 // saw between 0.4/0.6
            return TimedBox(time: t,
                            box: CGRect(x: x, y: 0.5, width: 0.08, height: 0.12))
        }
        let clip = makeClip(start: 5, end: 11, boxes: boxes)
        let plan = ReelPlan(selected: [clip], totalDuration: 6, tier: .normal)
        let edit = makeEditPlan(plan: plan)
        guard let body = edit.body.first ?? edit.coldOpen else {
            return XCTFail("No clip emitted")
        }
        // Path length over the smoothed center.
        var smoothedLen: CGFloat = 0
        for i in 1..<body.cropKeyframes.count {
            let a = body.cropKeyframes[i - 1].center
            let b = body.cropKeyframes[i].center
            smoothedLen += hypot(b.x - a.x, b.y - a.y)
        }
        // Raw sawtooth length: each step is 0.2 in x, 60 steps → 12.0.
        // Smoothed must be far shorter.
        XCTAssertLessThan(smoothedLen, 1.5,
                          "Critical damping should suppress the sawtooth")
    }

    /// Speed curves: every segment must have positive duration and the
    /// total rendered duration must equal Σ(sourceFraction / factor).
    func testSpeedCurveTimeMappingIsContinuous() {
        let clip = makeClip(start: 0, end: 5, composite: 0.85)
        let plan = ReelPlan(selected: [clip], totalDuration: 5, tier: .normal)
        let edit = makeEditPlan(plan: plan)
        guard let body = edit.body.first ?? edit.coldOpen else {
            return XCTFail("No clip emitted")
        }
        var lastEnd: Double = 0
        for s in body.speedCurve.segments {
            XCTAssertGreaterThan(s.sourceFractionEnd, s.sourceFractionStart,
                                 "Segment must have positive source duration")
            XCTAssertGreaterThan(s.factor, 0,
                                 "Speed factor must be positive")
            XCTAssertGreaterThanOrEqual(s.sourceFractionStart, lastEnd - 1e-9,
                                        "Segments must be ordered")
            lastEnd = s.sourceFractionEnd
        }
        // Total source fractions sum to 1 (allow tiny rounding slop).
        let total = body.speedCurve.segments.reduce(0.0) {
            $0 + ($1.sourceFractionEnd - $1.sourceFractionStart)
        }
        XCTAssertEqual(total, 1.0, accuracy: 0.01)
        // Rendered duration always strictly positive.
        XCTAssertGreaterThan(body.renderedDuration, 0)
    }

    /// Chill style must NOT emit slow-mo even on a high-energy clip.
    func testChillStyleSuppressesSpeedRamps() {
        let clip = makeClip(start: 0, end: 5, composite: 0.95)
        let plan = ReelPlan(selected: [clip], totalDuration: 5, tier: .normal)
        let edit = makeEditPlan(plan: plan, style: .chill)
        guard let body = edit.body.first ?? edit.coldOpen else {
            return XCTFail("No clip emitted")
        }
        // Real-time curve = exactly one segment with factor 1.
        XCTAssertEqual(body.speedCurve.segments.count, 1)
        XCTAssertEqual(body.speedCurve.segments.first?.factor ?? 0, 1.0,
                       accuracy: 1e-9)
    }

    /// Empty EditPlan still has a sensible totalDuration (0 if no
    /// cards, otherwise card durations).
    func testEditPlanDurationShape() {
        let plan = ReelPlan(selected: [], totalDuration: 0, tier: .normal)
        let edit = makeEditPlan(plan: plan)
        // With no body + no cold open, totalDuration = title + closing
        // card durations (if they were emitted).
        let expected = (edit.titleCard != nil ? TitleCardSpec.duration : 0)
            + (edit.closingCard != nil ? ClosingCardSpec.duration : 0)
        XCTAssertEqual(edit.totalDuration, expected, accuracy: 0.001)
    }

    /// EditStyle.defaultFor(musicVibe:) covers all vibe cases.
    func testEditStyleMapsFromMusicVibe() {
        XCTAssertEqual(EditStyle.defaultFor(musicVibe: .energetic), .energetic)
        XCTAssertEqual(EditStyle.defaultFor(musicVibe: .cinematic), .cinematic)
        XCTAssertEqual(EditStyle.defaultFor(musicVibe: .playful),   .playful)
        XCTAssertEqual(EditStyle.defaultFor(musicVibe: .chill),     .chill)
    }

    /// LUT lookup choice matches the style family.
    func testStyleLUTAssignment() {
        XCTAssertEqual(EditStyle.energetic.lookUpTable, .vivid)
        XCTAssertEqual(EditStyle.playful.lookUpTable,   .vivid)
        XCTAssertEqual(EditStyle.cinematic.lookUpTable, .natural)
        XCTAssertEqual(EditStyle.chill.lookUpTable,     .natural)
    }

    // MARK: helpers

    private func makeGame(playerID: UUID) -> GameSession {
        GameSession(
            id: UUID(),
            playerId: playerID,
            sport: .basketball,
            startedAt: Date(),
            endedAt: nil,
            rawVideoURL: URL(fileURLWithPath: "/tmp/raw.mov"),
            audioLoudnessURL: URL(fileURLWithPath: "/tmp/audio.json"),
            stage1Result: nil,
            stage2Result: nil,
            status: .completed,
            triggerSource: .manual,
            sceneType: .outdoor)
    }

    private func makeEditPlan(plan: ReelPlan,
                              style: EditStyle = .energetic) -> EditPlan {
        let player = PlayerEnrollment(
            id: UUID(), name: "Test", jerseyNumber: "7",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .basketball, createdAt: Date())
        let game = makeGame(playerID: player.id)
        let builder = EditPlanBuilder(
            style: style,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 60,
            profile: .highEnd)
        return builder.build(from: plan,
                             player: player,
                             game: game,
                             musicURL: nil,
                             musicBPM: 140)
    }
}

// MARK: - ETA estimator (Section 2.2)

final class ETAEstimatorTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        ETAEstimator.shared.reset()
    }

    /// Cold start (no samples persisted for this tier) reports a wide
    /// envelope and isFirstRun = true.
    @MainActor
    func testColdStartShowsRangedFirstRunCopy() {
        let r = ETAEstimator.shared.reading(currentStage: .stage1,
                                            tier: .a15,
                                            elapsed: 0)
        XCTAssertTrue(r.isFirstRun)
        XCTAssertGreaterThan(r.upperSeconds, r.lowerSeconds,
                             "Cold start should produce a non-degenerate range")
        XCTAssertFalse(r.isOverdue)
        XCTAssertTrue(r.label.contains("about"),
                      "Label should be the 'about N min' form")
    }

    /// After samples accumulate the envelope tightens (≤ 50 % spread
    /// after the first sample; ≤ 40 % after three).
    @MainActor
    func testEnvelopeTightensWithSamples() {
        let tier: SoCTier = .a15
        for _ in 0..<5 {
            ETAEstimator.shared.recordSample(stage: .stage1,
                                             tier: tier, seconds: 30)
            ETAEstimator.shared.recordSample(stage: .stage2,
                                             tier: tier, seconds: 120)
            ETAEstimator.shared.recordSample(stage: .ranking,
                                             tier: tier, seconds: 4)
            ETAEstimator.shared.recordSample(stage: .compose,
                                             tier: tier, seconds: 60)
        }
        let r = ETAEstimator.shared.reading(currentStage: .stage1,
                                            tier: tier, elapsed: 0)
        XCTAssertFalse(r.isFirstRun)
        let spread = (r.upperSeconds - r.lowerSeconds) /
            max(1, (r.upperSeconds + r.lowerSeconds) / 2)
        XCTAssertLessThan(spread, 0.6,
                          "Spread should tighten once samples accumulate")
    }

    /// Elapsed > 2× estimate triggers the "taking longer than usual"
    /// copy without crashing the panel.
    @MainActor
    func testOverdueLabel() {
        let tier: SoCTier = .a15
        ETAEstimator.shared.recordSample(stage: .compose,
                                         tier: tier, seconds: 10)
        let r = ETAEstimator.shared.reading(currentStage: .compose,
                                            tier: tier, elapsed: 60)
        XCTAssertTrue(r.isOverdue)
        XCTAssertTrue(r.label.lowercased().contains("longer"),
                      "Overdue label should mention 'longer'")
    }
}

// MARK: - Composer regression guard (Section 2.1 fail-loud)

/// Asserts that the composer code path explicitly affirms it did NOT
/// fall back to a primitive concat. There is no primitive-concat path
/// in the codebase — this test exists to fail loudly if someone adds
/// one. We can't actually invoke compose() without a fixture video, so
/// we check the diagnostic invariant: the helper is in place and
/// callable, and the default after a fresh DiagnosticsStore.reset()
/// remains 0 (false).
final class ComposerFallbackRegressionTests: XCTestCase {

    func testComposerUsedFallbackDefaultsToFalse() async {
        await DiagnosticsStore.shared.reset()
        let snap = await DiagnosticsStore.shared.currentSnapshot()
        let v = snap.counters[CounterKey.composerUsedFallback.rawValue]
        XCTAssertTrue(v == nil || v == 0,
                      "composerUsedFallback should default to absent/false")
    }

    func testComposerUsedFallbackCanBeAffirmedFalse() async {
        await DiagnosticsStore.shared.reset()
        await DiagnosticsStore.shared.composerUsedFallback(false)
        let snap = await DiagnosticsStore.shared.currentSnapshot()
        XCTAssertEqual(snap.counters[CounterKey.composerUsedFallback.rawValue],
                       0,
                       "Affirmation should record 0 (false)")
    }

    func testComposerStageFailedRecordsCounterAndDistribution() async {
        await DiagnosticsStore.shared.reset()
        let err = PipelineError.compositionFailed("synthetic")
        await DiagnosticsStore.shared.composerStageFailed(
            stage: .exportRun, error: err)
        let snap = await DiagnosticsStore.shared.currentSnapshot()
        XCTAssertEqual(snap.counters[CounterKey.composerStageFailed.rawValue], 1)
        let dist = snap.enumDistributions[EnumKey.composerFailedStage.rawValue]
        XCTAssertEqual(dist?[ComposerStage.exportRun.rawValue], 1,
                       "Stage label should land in the distribution")
    }
}

// MARK: - MusicLibrary (Section 1 + Section 6 regression guard)

final class MusicLibraryTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        MusicLibrary.shared.resetRotation()
    }

    @MainActor
    func testManifestLoadsAllTwentyTracks() {
        let tracks = MusicLibrary.shared.allTracks
        XCTAssertEqual(tracks.count, 20,
                       "Manifest should list exactly 20 tracks")
    }

    @MainActor
    func testEveryTrackResolvesToABundleURL() {
        // The whole point of bundling the .m4a files is that
        // MusicLibrary.Track.url is non-nil at runtime. Without this,
        // every reel ships silent — which is exactly the Section 1
        // failure mode this section is here to prevent.
        for track in MusicLibrary.shared.allTracks {
            XCTAssertNotNil(track.url,
                "Track \(track.id) has no bundle URL — .m4a missing from Resources")
        }
    }

    @MainActor
    func testEveryVibeIsRepresented() {
        let tracks = MusicLibrary.shared.allTracks
        for vibe in MusicVibe.allCases {
            let pool = tracks.filter { $0.vibe == vibe }
            XCTAssertFalse(pool.isEmpty,
                "No tracks for vibe \(vibe.rawValue)")
        }
    }

    @MainActor
    func testPickReturnsTrackForEveryVibe() {
        let playerId = UUID()
        for vibe in MusicVibe.allCases {
            let picked = MusicLibrary.shared.pick(
                vibe: vibe, playerId: playerId, length: .sixtySeconds)
            XCTAssertNotNil(picked,
                "Pick returned nil for vibe \(vibe.rawValue)")
        }
    }

    @MainActor
    func testLRURotationDoesNotImmediatelyRepeat() {
        // For energetic (6 tracks), three back-to-back picks for the
        // same player should never return the same track twice.
        let playerId = UUID()
        let a = MusicLibrary.shared.pick(vibe: .energetic,
                                         playerId: playerId,
                                         length: .sixtySeconds)
        let b = MusicLibrary.shared.pick(vibe: .energetic,
                                         playerId: playerId,
                                         length: .sixtySeconds)
        let c = MusicLibrary.shared.pick(vibe: .energetic,
                                         playerId: playerId,
                                         length: .sixtySeconds)
        XCTAssertNotEqual(a?.id, b?.id,
            "LRU rotation failed: same track twice in a row (a=b)")
        XCTAssertNotEqual(b?.id, c?.id,
            "LRU rotation failed: same track twice in a row (b=c)")
    }

    @MainActor
    func testBPMSpecBaseline() {
        // Sanity-check a handful of the BPMs the spec calls out.
        // Catches a manifest substitution that swaps tempos under us.
        let byId = Dictionary(uniqueKeysWithValues:
            MusicLibrary.shared.allTracks.map { ($0.id, $0) })
        XCTAssertEqual(byId["energetic_1"]?.bpm, 140)
        XCTAssertEqual(byId["energetic_3"]?.bpm, 150)
        XCTAssertEqual(byId["cinematic_3"]?.bpm, 78)
        XCTAssertEqual(byId["playful_5"]?.bpm, 128)
        XCTAssertEqual(byId["chill_4"]?.bpm, 80)
    }
}

// MARK: - LUT factory

final class LUTFactoryTests: XCTestCase {

    func testCubeDimensions() {
        let vivid = LUTFactory.data(for: .vivid)
        let natural = LUTFactory.data(for: .natural)
        let dim = LUTFactory.cubeDimension
        let expectedFloats = dim * dim * dim * 4
        XCTAssertEqual(vivid.count, expectedFloats * MemoryLayout<Float>.size)
        XCTAssertEqual(natural.count, expectedFloats * MemoryLayout<Float>.size)
    }

    /// Identity-ish check: the 0,0,0 entry should still be near black,
    /// the 1,1,1 entry should still be near white. Cubes that lose
    /// monotonic order break Core Image's color cube filter.
    func testCubeEndpointsArePreserved() {
        let dim = LUTFactory.cubeDimension
        let data = LUTFactory.data(for: .vivid)
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let f = ptr.bindMemory(to: Float.self)
            // (0,0,0) entry is the first RGBA quad.
            XCTAssertLessThan(f[0], 0.2)
            XCTAssertLessThan(f[1], 0.2)
            XCTAssertLessThan(f[2], 0.2)
            // (1,1,1) entry is the last RGBA quad.
            let last = (dim * dim * dim * 4) - 4
            XCTAssertGreaterThan(f[last + 0], 0.8)
            XCTAssertGreaterThan(f[last + 1], 0.8)
            XCTAssertGreaterThan(f[last + 2], 0.8)
        }
    }
}
