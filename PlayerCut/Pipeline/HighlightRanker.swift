//
//  HighlightRanker.swift
//  PlayerCut
//
//  Selects the final clips for the reel. The hard contract: this code
//  must ALWAYS produce a non-empty plan when given a positive video
//  duration. There is no failure mode — every recording yields a reel.
//
//  Strategy: three tiers, descending in confidence.
//   1. Tier 1 (Normal): composite scores cross an absolute "interesting"
//      threshold (default 0.45). Diversity-respecting top-N.
//   2. Tier 2 (Weak signals): lower the threshold twice (0.30 → 0.15),
//      then switch to relative ranking — normalize all moments to [0, 1]
//      across the recording and pick the best available regardless of
//      absolute score. Prefer windows where the identified player is
//      present.
//   3. Tier 3 (Montage fallback): no candidate moments survived. Evenly
//      sample the recording timeline into N segments and take a clip
//      from each. Watchable even from black / silent / solo-practice
//      footage.
//
//  Composite per spec:
//      moment_score =
//          0.35 * identification_confidence
//        + 0.20 * player_centrality
//        + 0.20 * action_intensity
//        + 0.15 * audio_excitement
//        + 0.05 * reaction_bonus
//        + 0.05 * scene_motion
//
//  // SOURCE: weighting approach drawn from IBM CVPR 2018 "The
//  // excitement of sports" and arXiv 2501.16100 — accessed 2026-05-19.
//  // Youth-sport-specific values are 🟡 inferred pending labeled-corpus
//  // tuning (see PlayerCut/Documentation/KnowledgeBank.md).
//

import Foundation
import os.log

// MARK: - Plan + clip types

struct ReelPlan {
    var selected: [SelectedClip]
    var totalDuration: Double
    /// Which fallback tier produced this plan. Surfaced into
    /// GameSession.rankerTierUsed and DiagnosticsStore.
    var tier: RankerTier = .normal
}

struct SelectedClip {
    let moment: ScoredMoment
    var clipStart: Double
    var clipEnd: Double
    var duration: Double { clipEnd - clipStart }
}

// MARK: - Weights (composite term coefficients)

/// Weights applied to the six composite terms. Per-sport profiles
/// nudge these from the defaults — see `profile(for:)`. All weights
/// must sum to ~1; the ranker re-normalizes defensively.
struct RankerWeights {
    var identification: Float = 0.35
    var centrality: Float     = 0.20
    var action: Float         = 0.20
    var audio: Float          = 0.15
    var reaction: Float       = 0.05
    var sceneMotion: Float    = 0.05

    var sum: Float {
        identification + centrality + action + audio + reaction + sceneMotion
    }

    /// Sport-specific weight profiles. Starting points only — 🟡 inferred.
    /// Replace with values from a labeled-corpus sweep when available.
    static func profile(for sport: Sport) -> RankerWeights {
        var w = RankerWeights()
        switch sport {
        case .basketball:
            // Vertical motion + drives matter more; scene cuts less.
            w.action      += 0.05
            w.sceneMotion -= 0.03
            w.identification -= 0.02
        case .soccer:
            // Field motion is part of every play — keep scene motion.
            w.sceneMotion += 0.03
            w.action      += 0.02
            w.identification -= 0.05
        case .pickleball:
            // Impact transients (paddle-on-ball) carry the highlights.
            w.audio  += 0.05
            w.action -= 0.05
        case .lacrosse, .footballAmerican:
            w.action += 0.03
            w.audio  += 0.02
            w.sceneMotion -= 0.05
        }
        return w
    }
}

// MARK: - Config

struct RankerConfig {
    var targetTotalDuration: Double = 60.0
    var minClipDuration: Double = 4.0
    var maxClipDuration: Double = 6.0
    var hardMaxClipDuration: Double = 8.0   // for exceptional moments
    var minSeparation: Double = 30.0        // seconds between clip centers
    var minClips: Int = 8
    var maxClips: Int = 14
    /// Below 0.80 so a fully-credited moment after the six-term
    /// composite recompute (which caps near 0.85 when audio/motion
    /// default to 0.5) can still trigger the exceptional-clip path.
    /// // SOURCE: tuned to recompose ceiling, not corpus-derived.
    var exceptionalScoreThreshold: Float = 0.80

    /// Tier 1 floor. Moments below this score are *not* part of the
    /// normal selection pass; Tier 2 handles them.
    var tier1Threshold: Float = 0.45
    /// First Tier-2 relaxation.
    var tier2ThresholdA: Float = 0.30
    /// Second Tier-2 relaxation.
    var tier2ThresholdB: Float = 0.15

    /// Preset tuned per reel length. Longer reels relax diversity
    /// (more clips fit) and lean on slightly longer per-clip durations.
    static func `for`(length: ReelLength) -> RankerConfig {
        var c = RankerConfig()
        c.targetTotalDuration = length.targetSeconds
        switch length {
        case .sixtySeconds:
            c.minClips = 10; c.maxClips = 14
            c.minClipDuration = 4; c.maxClipDuration = 6
            c.minSeparation = 30
        case .twoMinutes:
            c.minClips = 18; c.maxClips = 24
            c.minClipDuration = 5; c.maxClipDuration = 7
            c.minSeparation = 25
        case .threeMinutes:
            c.minClips = 25; c.maxClips = 35
            c.minClipDuration = 6; c.maxClipDuration = 8
            c.minSeparation = 20
        case .fiveMinutes:
            c.minClips = 40; c.maxClips = 55
            c.minClipDuration = 6; c.maxClipDuration = 10
            c.minSeparation = 15
        }
        return c
    }
}

// MARK: - Ranker

final class HighlightRanker {

    private let log = Logger(subsystem: "com.playercut.app", category: "Ranker")
    private let config: RankerConfig
    private let weights: RankerWeights

    init(config: RankerConfig = RankerConfig(),
         weights: RankerWeights = RankerWeights()) {
        self.config = config
        self.weights = weights
    }

    /// Legacy signature retained for unit tests that pre-date the
    /// never-reject contract. Equivalent to passing
    /// `videoDuration = 0` — Tier 3 fallback is disabled in that path
    /// because the caller has no timeline to montage against.
    func selectClips(from moments: [ScoredMoment]) -> ReelPlan {
        selectClips(from: moments, videoDuration: 0)
    }

    /// Primary entry point. `videoDuration` is the source recording
    /// length in seconds — required for the Tier 3 montage fallback.
    func selectClips(from moments: [ScoredMoment],
                     videoDuration: Double) -> ReelPlan {

        let scored = moments.map { withRecomputedComposite($0) }

        // Tier 1 — normal path. Succeeds when it picks enough clips
        // OR when it picked every moment available (i.e. the caller
        // simply doesn't have more material). Otherwise fall through
        // to Tier 2 which has a wider candidate pool (relaxed
        // thresholds, relative ranking) and is more likely to fill
        // the reel.
        let t1 = tier1(scored)
        let t1Target = min(config.minClips, scored.count)
        if t1.count >= t1Target && !t1.isEmpty {
            let plan = finalizePlan(t1, tier: .normal)
            log.info("Ranker → Tier 1 (\(plan.selected.count) clips, \(plan.totalDuration, format: .fixed(precision: 1))s)")
            return plan
        }

        // Tier 2 — relaxed threshold, then relative ranking.
        let t2 = tier2(scored)
        if !t2.isEmpty {
            let plan = finalizePlan(t2, tier: .weakSignals)
            log.info("Ranker → Tier 2 weak-signals (\(plan.selected.count) clips, \(plan.totalDuration, format: .fixed(precision: 1))s)")
            return plan
        }

        // Tier 1 ran but didn't fill, and Tier 2 found nothing more —
        // fall back to whatever Tier 1 picked rather than going all the
        // way down to montage. Honors the never-reject contract while
        // preferring real signals.
        if !t1.isEmpty {
            let plan = finalizePlan(t1, tier: .normal)
            log.info("Ranker → Tier 1 short reel (\(plan.selected.count) clips, \(plan.totalDuration, format: .fixed(precision: 1))s)")
            return plan
        }

        // Tier 3 — montage from raw timeline.
        let plan = tier3Montage(videoDuration: videoDuration)
        log.info("Ranker → Tier 3 montage (\(plan.selected.count) clips, \(plan.totalDuration, format: .fixed(precision: 1))s)")
        return plan
    }

    // MARK: - Tier 1: absolute threshold + diversity

    private func tier1(_ moments: [ScoredMoment]) -> [SelectedClip] {
        let qualifying = moments.filter { $0.compositeScore >= config.tier1Threshold }
        guard !qualifying.isEmpty else { return [] }
        return diversitySelect(from: qualifying.sorted { $0.compositeScore > $1.compositeScore })
    }

    // MARK: - Tier 2: two threshold relaxations, then relative ranking

    private func tier2(_ moments: [ScoredMoment]) -> [SelectedClip] {
        guard !moments.isEmpty else { return [] }
        for threshold in [config.tier2ThresholdA, config.tier2ThresholdB] {
            let qualifying = moments.filter { $0.compositeScore >= threshold }
            if !qualifying.isEmpty {
                let picks = diversitySelect(
                    from: qualifying.sorted { $0.compositeScore > $1.compositeScore })
                if !picks.isEmpty {
                    log.info("Ranker tier 2: threshold \(threshold) yielded \(picks.count) clips")
                    return picks
                }
            }
        }
        // Final relaxation: relative ranking. Normalize composites to
        // [0, 1] across the recording and pick the top N regardless of
        // absolute score. Prefer windows where the identified player
        // is present (identificationConfidence > 0) as a tiebreaker.
        let maxScore = moments.map { $0.compositeScore }.max() ?? 1.0
        let denom = max(0.0001, maxScore)
        let normalized = moments.map { m -> (ScoredMoment, Float) in
            let rel = m.compositeScore / denom
            let presenceBonus: Float = m.identificationConfidence > 0 ? 0.05 : 0
            return (m, rel + presenceBonus)
        }
        let sorted = normalized.sorted { $0.1 > $1.1 }.map { $0.0 }
        let picks = diversitySelect(from: sorted)
        log.info("Ranker tier 2 relative: yielded \(picks.count) clips")
        return picks
    }

    // MARK: - Tier 3: evenly-sampled montage

    private func tier3Montage(videoDuration: Double) -> ReelPlan {
        guard videoDuration > 0 else {
            // No timeline to sample — return an empty plan rather than
            // crashing. The orchestrator treats this as an invariant
            // violation and logs it; users still see a "completed" game
            // pointer in the UI even if the reel is zero-length.
            return ReelPlan(selected: [], totalDuration: 0,
                            tier: .montageFallback)
        }
        let n = config.minClips
        let segment = videoDuration / Double(n)
        var clips: [SelectedClip] = []
        for i in 0..<n {
            let segStart = Double(i) * segment
            let segEnd = segStart + segment
            let length = min(config.minClipDuration, segment)
            let center = (segStart + segEnd) / 2
            let clipStart = max(0, center - length / 2)
            let clipEnd = min(videoDuration, clipStart + length)
            let dummyWindow = CandidateWindow(
                id: UUID(),
                startTime: clipStart,
                endTime: clipEnd,
                audioScore: 0,
                motionScore: 0)
            let dummyMoment = ScoredMoment(
                id: UUID(),
                window: dummyWindow,
                identificationConfidence: 0,
                activityScore: 0,
                playerBoundingBoxes: [],
                compositeScore: 0)
            clips.append(SelectedClip(moment: dummyMoment,
                                      clipStart: clipStart,
                                      clipEnd: clipEnd))
        }
        let total = clips.reduce(0.0) { $0 + $1.duration }
        return ReelPlan(selected: clips,
                        totalDuration: total,
                        tier: .montageFallback)
    }

    // MARK: - Diversity-respecting selection

    /// Greedy top-N with minSeparation diversity. Falls through to a
    /// secondary backfill pass when fewer than minClips survive — but
    /// will never reject; if a single moment is offered, one clip is
    /// returned.
    private func diversitySelect(from sorted: [ScoredMoment]) -> [SelectedClip] {
        guard !sorted.isEmpty else { return [] }
        var selected: [SelectedClip] = []
        var totalDuration: Double = 0
        for moment in sorted {
            if selected.count >= config.maxClips { break }
            if totalDuration >= config.targetTotalDuration { break }
            let center = (moment.window.startTime + moment.window.endTime) / 2
            let tooClose = selected.contains { picked in
                let pc = (picked.clipStart + picked.clipEnd) / 2
                return abs(pc - center) < config.minSeparation
            }
            if tooClose { continue }

            let targetLength = clipLength(for: moment)
            let halfLength = targetLength / 2
            let anchor = densestAnchor(in: moment) ?? center
            var clipStart = max(0, anchor - halfLength)
            var clipEnd = clipStart + targetLength
            if clipStart < moment.window.startTime - 1 {
                clipStart = max(0, moment.window.startTime - 1)
                clipEnd = clipStart + targetLength
            }
            if clipEnd > moment.window.endTime + 1 {
                clipEnd = moment.window.endTime + 1
                clipStart = max(0, clipEnd - targetLength)
            }
            selected.append(SelectedClip(moment: moment,
                                         clipStart: clipStart,
                                         clipEnd: clipEnd))
            totalDuration += (clipEnd - clipStart)
        }
        // Backfill toward minClips, but respect a RELAXED diversity
        // rule (half of minSeparation). Without this, dense-cluster
        // recordings pile up multiple near-identical clips just to
        // hit minClips — which is exactly what the diversity rule is
        // supposed to prevent.
        let relaxedSeparation = config.minSeparation * 0.5
        while selected.count < config.minClips {
            let already = Set(selected.map { $0.moment.id })
            let candidate = sorted.first(where: { m in
                guard !already.contains(m.id) else { return false }
                let mc = (m.window.startTime + m.window.endTime) / 2
                return !selected.contains { picked in
                    let pc = (picked.clipStart + picked.clipEnd) / 2
                    return abs(pc - mc) < relaxedSeparation
                }
            })
            // If no candidate respects relaxed diversity, accept the
            // shorter reel rather than pile up duplicates.
            guard let next = candidate else { break }
            let length = config.minClipDuration
            let center = (next.window.startTime + next.window.endTime) / 2
            let start = max(0, center - length / 2)
            selected.append(SelectedClip(moment: next,
                                         clipStart: start,
                                         clipEnd: start + length))
            totalDuration += length
        }
        return selected
    }

    // MARK: - Composite recomputation

    /// Maps the ScoredMoment's existing fields onto the six-term
    /// composite. `playerCentrality` and `reactionBonus` are currently
    /// proxied from identificationConfidence (centrality) and 0
    /// (reaction) until the tracker/pose providers land. The
    /// SignalProvider rollout in a follow-up will replace these proxies.
    private func withRecomputedComposite(_ m: ScoredMoment) -> ScoredMoment {
        let id        = m.identificationConfidence
        let centrality = id  // proxy
        let action    = m.activityScore
        let audio     = m.window.audioScore
        let reaction: Float = 0   // proxy until reaction providers ship
        let scene     = m.window.motionScore

        let s =
              weights.identification * id
            + weights.centrality     * centrality
            + weights.action         * action
            + weights.audio          * audio
            + weights.reaction       * reaction
            + weights.sceneMotion    * scene
        let normalized = (weights.sum > 0) ? s / weights.sum : s
        var updated = m
        updated.compositeScore = min(1.0, max(0.0, normalized))
        return updated
    }

    // MARK: - Plan finalization

    private func finalizePlan(_ clips: [SelectedClip],
                              tier: RankerTier) -> ReelPlan {
        let ordered = clips.sorted { $0.clipStart < $1.clipStart }
        let total = ordered.reduce(0.0) { $0 + $1.duration }
        return ReelPlan(selected: ordered, totalDuration: total, tier: tier)
    }

    // MARK: - Clip-length helpers

    private func clipLength(for moment: ScoredMoment) -> Double {
        if moment.compositeScore >= config.exceptionalScoreThreshold {
            return config.hardMaxClipDuration
        }
        let normalized = Double(moment.compositeScore)
        let span = config.maxClipDuration - config.minClipDuration
        return config.minClipDuration + span * normalized
    }

    private func densestAnchor(in moment: ScoredMoment) -> Double? {
        guard !moment.playerBoundingBoxes.isEmpty else { return nil }
        var buckets: [Int: Int] = [:]
        for box in moment.playerBoundingBoxes {
            let bucket = Int(box.time * 2)
            buckets[bucket, default: 0] += 1
        }
        guard let best = buckets.max(by: { $0.value < $1.value }) else { return nil }
        return Double(best.key) / 2.0
    }
}
