import XCTest
@testable import PlayerCut

final class PlayerCutTests: XCTestCase {
    func testSmoke() {
        XCTAssertEqual(1 + 1, 2)
    }
}

// MARK: - DeviceCapabilities (Section 1 adaptive capture)

final class DeviceCapabilitiesTests: XCTestCase {

    // ----- Tier mapping from utsname machine string -----

    func testTierMappingA13Family() {
        for id in ["iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8"] {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a13, "Expected \(id) to map to A13")
        }
    }

    func testTierMappingA14Family() {
        for id in ["iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4"] {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a14, "Expected \(id) to map to A14")
        }
    }

    func testTierMappingA15Family() {
        // iPhone 13/14 + SE 3rd gen (iPhone14,6 has A15).
        let ids = ["iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
                   "iPhone14,6", "iPhone14,7", "iPhone14,8"]
        for id in ids {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a15, "Expected \(id) to map to A15")
        }
    }

    func testTierMappingA16Family() {
        for id in ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5"] {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a16, "Expected \(id) to map to A16")
        }
    }

    func testTierMappingA17() {
        for id in ["iPhone16,1", "iPhone16,2"] {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a17, "Expected \(id) to map to A17")
        }
    }

    func testTierMappingA18Plus() {
        // iPhone 16 family (A18 / A18 Pro) and any future iPhone17,*
        for id in ["iPhone17,1", "iPhone17,3", "iPhone18,1"] {
            XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: id),
                           .a18plus, "Expected \(id) to map to A18+")
        }
    }

    func testTierMappingUnknownIdentifier() {
        // Simulator + pre-release identifiers.
        XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: "x86_64"),
                       .unknown)
        XCTAssertEqual(DeviceCapabilities.tier(forMachineIdentifier: "arm64"),
                       .unknown)
        // Unknown collapses to A17 for recipe purposes.
        XCTAssertEqual(DeviceCapabilities.effectiveTier(.unknown), .a17)
    }

    // ----- Ideal recipe per tier -----

    func testIdealRecipeA13() {
        let r = DeviceCapabilities.idealRecipe(for: .a13)
        XCTAssertEqual(r.resolution, .fhd1080)
        XCTAssertEqual(r.fps, 60)
        XCTAssertEqual(r.codec, .hevc)
    }

    func testIdealRecipeMidTierIs4K60() {
        for tier: SoCTier in [.a14, .a15, .a16] {
            let r = DeviceCapabilities.idealRecipe(for: tier)
            XCTAssertEqual(r.resolution, .uhd4k, "tier \(tier)")
            XCTAssertEqual(r.fps, 60, "tier \(tier)")
            XCTAssertEqual(r.codec, .hevc, "tier \(tier)")
            XCTAssertEqual(r.stabilization, .standard, "tier \(tier)")
        }
    }

    func testIdealRecipeA17PlusGetsCinematicStabilization() {
        for tier: SoCTier in [.a17, .a18plus] {
            let r = DeviceCapabilities.idealRecipe(for: tier)
            XCTAssertEqual(r.resolution, .uhd4k)
            XCTAssertEqual(r.fps, 60)
            XCTAssertEqual(r.stabilization, .cinematic)
        }
    }

    func testRealSlowMoSourceMatchesFPS() {
        XCTAssertTrue(DeviceCapabilities.idealRecipe(for: .a15).providesRealSlowMoSource)
        let degraded = CaptureRecipe(resolution: .fhd1080, fps: 30)
        XCTAssertFalse(degraded.providesRealSlowMoSource)
    }

    // ----- Thermal + battery ladder -----

    private func ideal4K60() -> CaptureRecipe {
        CaptureRecipe(resolution: .uhd4k, fps: 60,
                      codec: .hevc, stabilization: .standard)
    }

    func testDowngradeNominalNoChange() {
        let base = ideal4K60()
        let out = DeviceCapabilities.downgrade(base,
                                               for: .nominal,
                                               batteryLevel: 0.95,
                                               lowPower: false)
        XCTAssertEqual(out, base)
    }

    func testDowngradeSeriousDropsTo1080p60() {
        let out = DeviceCapabilities.downgrade(ideal4K60(),
                                               for: .serious,
                                               batteryLevel: 0.95,
                                               lowPower: false)
        XCTAssertEqual(out.resolution, .fhd1080)
        XCTAssertEqual(out.fps, 60, "Serious keeps fps")
    }

    func testDowngradeBatteryUnder20DropsTo1080p60() {
        let out = DeviceCapabilities.downgrade(ideal4K60(),
                                               for: .nominal,
                                               batteryLevel: 0.15,
                                               lowPower: false)
        XCTAssertEqual(out.resolution, .fhd1080)
        XCTAssertEqual(out.fps, 60)
    }

    func testDowngradeCriticalDropsTo1080p30Standard() {
        let cinematic = CaptureRecipe(resolution: .uhd4k, fps: 60,
                                      codec: .hevc, stabilization: .cinematic)
        let out = DeviceCapabilities.downgrade(cinematic,
                                               for: .critical,
                                               batteryLevel: 0.95,
                                               lowPower: false)
        XCTAssertEqual(out.resolution, .fhd1080)
        XCTAssertEqual(out.fps, 30)
        XCTAssertEqual(out.stabilization, .standard)
    }

    func testDowngradeBatteryUnder10DropsTo1080p30() {
        let out = DeviceCapabilities.downgrade(ideal4K60(),
                                               for: .nominal,
                                               batteryLevel: 0.05,
                                               lowPower: false)
        XCTAssertEqual(out.resolution, .fhd1080)
        XCTAssertEqual(out.fps, 30)
    }

    func testDowngradeIgnoresUnknownBatteryLevel() {
        // batteryLevel == -1 → monitoring not enabled; treat as fine.
        let out = DeviceCapabilities.downgrade(ideal4K60(),
                                               for: .nominal,
                                               batteryLevel: -1,
                                               lowPower: false)
        XCTAssertEqual(out, ideal4K60())
    }

    func testDowngradeLowPowerCountsAsSerious() {
        let out = DeviceCapabilities.downgrade(ideal4K60(),
                                               for: .nominal,
                                               batteryLevel: 0.95,
                                               lowPower: true)
        XCTAssertEqual(out.resolution, .fhd1080)
        XCTAssertEqual(out.fps, 60)
    }

    // ----- Recipe codec/coding round-trip -----

    func testCaptureRecipeRoundTripsThroughJSON() throws {
        let original = CaptureRecipe(resolution: .uhd4k, fps: 60,
                                     codec: .hevc, stabilization: .cinematic)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureRecipe.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // ----- Live recipe collapses tier + state -----

    func testLiveRecipeRespectsThermalEvenOnTopTier() {
        let r = DeviceCapabilities.liveRecipe(for: .a18plus,
                                              thermal: .critical,
                                              batteryLevel: 0.95,
                                              lowPower: false)
        XCTAssertEqual(r.resolution, .fhd1080)
        XCTAssertEqual(r.fps, 30)
    }

    func testLiveRecipeNominalA17Gets4K60Cinematic() {
        let r = DeviceCapabilities.liveRecipe(for: .a17,
                                              thermal: .nominal,
                                              batteryLevel: 0.95,
                                              lowPower: false)
        XCTAssertEqual(r.resolution, .uhd4k)
        XCTAssertEqual(r.fps, 60)
        XCTAssertEqual(r.stabilization, .cinematic)
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
        // One exceptional moment plus enough separated normal-scoring
        // moments to fill the rest. The 3-tier ranker recomputes the
        // composite from the six-term weights — a raw input of 0.95
        // recomposes below the 0.85 exceptional threshold because
        // audio/motion defaults pull it down. Use 1.0 so the
        // recomposition lands at 0.85 and the exceptional clip-length
        // branch triggers.
        var moments = [makeMoment(center: 100, composite: 1.0)]
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

    /// Low-event sport (skill clinic, defensive game with no scoring):
    /// all moments below the exceptional threshold, well-separated, count
    /// under the default minClips. Ranker should return all of them as a
    /// short reel rather than producing zero.
    func testLowActivityNoExceptionalMomentsReturnAllClips() {
        let moments: [ScoredMoment] = (0..<8).enumerated().map { (i, _) in
            makeMoment(center: 60 + Double(i) * 60,
                       composite: 0.3 + Float(i) * 0.025)  // 0.300 … 0.475
        }
        let plan = HighlightRanker().selectClips(from: moments)
        XCTAssertEqual(plan.selected.count, 8,
                       "All low-activity moments should appear in the reel")
        XCTAssertGreaterThan(plan.totalDuration, 0)
        let starts = plan.selected.map { $0.clipStart }
        XCTAssertEqual(starts, starts.sorted(),
                       "Short-clip path must still order chronologically")
    }

    // MARK: - Never-reject 3-tier ranker

    /// Tier 1: composites above 0.45 → diversity-respecting selection,
    /// tier should be .normal.
    func testTier1NormalPath() {
        let moments = (0..<10).map { i in
            makeMoment(center: 60 + Double(i) * 60,
                       composite: 0.55 + Float(i) * 0.02)
        }
        let plan = HighlightRanker().selectClips(from: moments,
                                                 videoDuration: 800)
        XCTAssertEqual(plan.tier, .normal)
        XCTAssertGreaterThan(plan.selected.count, 0)
    }

    /// Tier 2: all composites below the 0.45 floor but above 0.15 →
    /// relaxed-threshold pass should still yield a plan.
    func testTier2RelaxedThreshold() {
        let moments = (0..<10).map { i in
            makeMoment(center: 60 + Double(i) * 60,
                       composite: 0.20 + Float(i) * 0.01)
        }
        let plan = HighlightRanker().selectClips(from: moments,
                                                 videoDuration: 800)
        XCTAssertEqual(plan.tier, .weakSignals)
        XCTAssertGreaterThan(plan.selected.count, 0)
    }

    /// Tier 2 relative-ranking branch: every composite below the
    /// 0.15 floor → ranker normalizes and still picks the best
    /// available.
    func testTier2RelativeRanking() {
        let moments = (0..<8).map { i in
            makeMoment(center: 60 + Double(i) * 60,
                       composite: Float(i) * 0.01)  // all in [0, 0.07]
        }
        let plan = HighlightRanker().selectClips(from: moments,
                                                 videoDuration: 800)
        XCTAssertEqual(plan.tier, .weakSignals,
                       "Below-floor composites should still resolve via relative ranking")
        XCTAssertGreaterThan(plan.selected.count, 0)
    }

    /// Tier 3: zero candidate moments + a positive video duration →
    /// montage fallback produces minClips evenly-sampled clips.
    func testTier3MontageFromEmptyMoments() {
        let plan = HighlightRanker().selectClips(from: [],
                                                 videoDuration: 600)
        XCTAssertEqual(plan.tier, .montageFallback)
        XCTAssertEqual(plan.selected.count, RankerConfig().minClips,
                       "Tier 3 should sample minClips segments")
        // Clips should be roughly evenly spaced across the timeline.
        let starts = plan.selected.map { $0.clipStart }
        XCTAssertEqual(starts, starts.sorted(),
                       "Montage clips must be chronological")
    }

    /// Single strong moment → 1-clip reel from Tier 1.
    func testSingleStrongMomentProducesOneClip() {
        let plan = HighlightRanker().selectClips(
            from: [makeMoment(center: 120, composite: 0.92)],
            videoDuration: 300)
        XCTAssertEqual(plan.tier, .normal)
        XCTAssertEqual(plan.selected.count, 1)
    }

    /// Pure invariant: zero moments AND zero duration → empty plan,
    /// tier still records as montageFallback so the orchestrator can
    /// log the regression and never crash.
    func testTier3GracefulOnEmptyEverything() {
        let plan = HighlightRanker().selectClips(from: [],
                                                 videoDuration: 0)
        XCTAssertEqual(plan.tier, .montageFallback)
        XCTAssertEqual(plan.selected.count, 0)
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
