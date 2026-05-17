import XCTest
@testable import PlayerCut

final class PlayerCutTests: XCTestCase {
    func testSmoke() {
        XCTAssertEqual(1 + 1, 2)
    }
}

// MARK: - Levenshtein

final class LevenshteinTests: XCTestCase {

    func testExactMatch() {
        XCTAssertEqual(levenshtein("23", "23"), 0)
        XCTAssertEqual(levenshtein("00", "00"), 0)
        XCTAssertEqual(levenshtein("", ""), 0)
    }

    func testSingleSubstitution() {
        XCTAssertEqual(levenshtein("23", "24"), 1)
        XCTAssertEqual(levenshtein("abc", "abd"), 1)
    }

    func testSingleInsertion() {
        XCTAssertEqual(levenshtein("23", "234"), 1)
        XCTAssertEqual(levenshtein("23", "123"), 1)
        XCTAssertEqual(levenshtein("23", "203"), 1)
    }

    func testSingleDeletion() {
        XCTAssertEqual(levenshtein("234", "23"), 1)
        XCTAssertEqual(levenshtein("123", "23"), 1)
    }

    func testEmptyInputs() {
        XCTAssertEqual(levenshtein("", "abc"), 3)
        XCTAssertEqual(levenshtein("xyz", ""), 3)
        XCTAssertEqual(levenshtein("", ""), 0)
    }

    /// Common Vision OCR confusions on jersey digits. These need to be
    /// edit-distance 1 so the fuzzy matcher gives them a non-zero score.
    func testCommonOCRConfusions() {
        XCTAssertEqual(levenshtein("L3", "13"), 1, "L↔1 should be one substitution")
        XCTAssertEqual(levenshtein("Z3", "23"), 1, "Z↔2 should be one substitution")
        XCTAssertEqual(levenshtein("8", "B"), 1, "8↔B should be one substitution")
        XCTAssertEqual(levenshtein("O", "0"), 1, "O↔0 should be one substitution")
    }

    func testSymmetry() {
        XCTAssertEqual(levenshtein("kitten", "sitting"),
                       levenshtein("sitting", "kitten"))
    }

    func testKnownDistance() {
        // Classic textbook example
        XCTAssertEqual(levenshtein("kitten", "sitting"), 3)
    }
}

// MARK: - HSVHistogram chi-squared

final class HSVHistogramTests: XCTestCase {

    private func uniform(_ value: Float, count: Int = 256) -> HSVHistogram {
        HSVHistogram(bins: Array(repeating: value, count: count))
    }

    func testIdenticalHistogramsZeroDistance() {
        let a = HSVHistogram(bins: (0..<256).map { _ in Float.random(in: 0...1) })
        XCTAssertEqual(a.chiSquared(to: a), 0, accuracy: 1e-6)
    }

    func testZeroHistogramsZeroDistance() {
        let z = uniform(0)
        XCTAssertEqual(z.chiSquared(to: z), 0, accuracy: 1e-6)
    }

    func testFullyDisjointHistogramsCloseToOne() {
        // a has all mass in first half of bins; b has all mass in second half.
        // The 0.5 factor in the formula makes the maximum disjoint distance 1.0.
        var aBins = [Float](repeating: 0, count: 256)
        var bBins = [Float](repeating: 0, count: 256)
        for i in 0..<128 { aBins[i] = 1.0 / 128 }
        for i in 128..<256 { bBins[i] = 1.0 / 128 }
        let a = HSVHistogram(bins: aBins)
        let b = HSVHistogram(bins: bBins)
        let d = a.chiSquared(to: b)
        XCTAssertEqual(d, 1.0, accuracy: 1e-5)
    }

    func testSymmetry() {
        let a = HSVHistogram(bins: (0..<256).map { i in Float(i % 7) / 21.0 })
        let b = HSVHistogram(bins: (0..<256).map { i in Float(i % 11) / 33.0 })
        XCTAssertEqual(a.chiSquared(to: b), b.chiSquared(to: a), accuracy: 1e-6)
    }

    func testPartialOverlapIsBetweenZeroAndOne() {
        var aBins = [Float](repeating: 0, count: 256)
        var bBins = [Float](repeating: 0, count: 256)
        for i in 0..<128 { aBins[i] = 1.0 / 128 }
        for i in 64..<192 { bBins[i] = 1.0 / 128 }
        let d = HSVHistogram(bins: aBins).chiSquared(to: HSVHistogram(bins: bBins))
        XCTAssertGreaterThan(d, 0)
        XCTAssertLessThan(d, 1)
    }
}

// MARK: - HighlightRanker.selectClips

final class HighlightRankerTests: XCTestCase {

    private func makeMoment(center: Double,
                            duration: Double = 10,
                            composite: Float,
                            audio: Float = 0.5,
                            motion: Float = 0.5) -> ScoredMoment {
        let window = CandidateWindow(
            id: UUID(),
            startTime: center - duration / 2,
            endTime: center + duration / 2,
            audioScore: audio,
            motionScore: motion
        )
        return ScoredMoment(
            id: UUID(),
            window: window,
            identificationConfidence: composite,
            activityScore: composite,
            playerBoundingBoxes: [],
            compositeScore: composite
        )
    }

    /// Default config — 8..14 clips, 30s separation. Enough non-overlapping
    /// candidates that diversity will actually be exercised.
    private func denseMoments() -> [ScoredMoment] {
        // 25 candidates spaced 40s apart so none collide on the 30s rule.
        // Scores descend so highest-score moments are early in real time too.
        (0..<25).map { i in
            makeMoment(center: 60 + Double(i) * 40,
                       composite: Float(0.9 - Double(i) * 0.02))
        }
    }

    func testDiversityRuleEnforced() {
        // Cluster 20 candidates within a single 30s window. The ranker should
        // pick at most one from this cluster (until the minClips backfill).
        let cluster: [ScoredMoment] = (0..<20).map { i in
            makeMoment(center: 100 + Double(i),  // 1s apart, all inside 30s
                       composite: Float(0.9 - Double(i) * 0.01))
        }
        // Add well-separated "anchor" moments so the picker doesn't have to
        // fall back to the relaxed minClips branch immediately.
        let anchors: [ScoredMoment] = (0..<10).map { i in
            makeMoment(center: 500 + Double(i) * 60,
                       composite: 0.5 - Float(i) * 0.01)
        }
        let plan = HighlightRanker().selectClips(from: cluster + anchors)

        // The PRIMARY (diversity-respecting) pass should pick exactly one
        // from the cluster. Then the minClips backfill may add more, but
        // the primary picks must all be ≥30s apart.
        //
        // We assert that among the first picks (those satisfying diversity),
        // no two cluster members appear next to each other within 30s.
        // Easier check: verify that primary-pass clips are mutually spaced.
        //
        // Since the backfill ignores separation, we instead verify the
        // first selected clip's neighbourhood: at most one selected clip
        // should center within [85, 130] (the cluster span + buffer) UNLESS
        // backfill kicked in — which only happens when we'd otherwise have
        // < minClips. With 10 well-spaced anchors that's not the case.
        let centers = plan.selected.map { ($0.clipStart + $0.clipEnd) / 2 }
        let inClusterRange = centers.filter { $0 >= 85 && $0 <= 135 }
        XCTAssertEqual(inClusterRange.count, 1,
                       "Diversity should keep only one clip from the dense cluster")
    }

    func testClipCountWithinBounds() {
        let plan = HighlightRanker().selectClips(from: denseMoments())
        let cfg = RankerConfig()
        XCTAssertGreaterThanOrEqual(plan.selected.count, cfg.minClips)
        XCTAssertLessThanOrEqual(plan.selected.count, cfg.maxClips)
    }

    func testEmptyInputProducesEmptyPlan() {
        let plan = HighlightRanker().selectClips(from: [])
        XCTAssertEqual(plan.selected.count, 0)
        XCTAssertEqual(plan.totalDuration, 0)
    }

    func testOutputIsChronological() {
        let plan = HighlightRanker().selectClips(from: denseMoments())
        let starts = plan.selected.map { $0.clipStart }
        XCTAssertEqual(starts, starts.sorted(),
                       "Selected clips must be chronologically ordered")
    }

    func testExceptionalScoreGetsLongClip() {
        // One exceptional moment (score ≥ 0.85 → 8s clip) plus enough
        // separated normal-scoring moments to fill the rest.
        var moments = [makeMoment(center: 100, composite: 0.95)]
        moments += (1..<15).map { i in
            makeMoment(center: 100 + Double(i) * 40, composite: 0.5)
        }
        let plan = HighlightRanker().selectClips(from: moments)
        let exceptional = plan.selected.first { clip in
            clip.moment.compositeScore >= RankerConfig().exceptionalScoreThreshold
        }
        XCTAssertNotNil(exceptional, "Exceptional moment should appear in plan")
        XCTAssertEqual(exceptional?.duration ?? 0,
                       RankerConfig().hardMaxClipDuration,
                       accuracy: 1.5,
                       "Exceptional clip should be near 8s (allowing for window-edge clamping)")
    }

    func testNormalScoreClipsRespectMaxClipDuration() {
        // All moments below the exceptional threshold; clip lengths must
        // stay ≤ maxClipDuration (modulo small floating-point slop).
        let moments: [ScoredMoment] = (0..<12).map { i in
            makeMoment(center: 60 + Double(i) * 40, composite: 0.6)
        }
        let plan = HighlightRanker().selectClips(from: moments)
        for clip in plan.selected {
            // The clamping logic can briefly extend a clip by ≤1s when the
            // anchor sits at the window edge; allow that tolerance.
            XCTAssertLessThanOrEqual(clip.duration,
                                     RankerConfig().maxClipDuration + 1.01)
        }
    }
}
