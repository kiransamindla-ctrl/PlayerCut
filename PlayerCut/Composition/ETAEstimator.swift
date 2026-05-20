//
//  ETAEstimator.swift
//  PlayerCut/Composition
//
//  Live ETA for the composing screen. Persists per-SoC, per-stage EMA
//  durations to UserDefaults so the second reel on a given device is
//  noticeably tighter than the first ("about 2–4 min" → "about 90 s").
//
//  Model: every pipeline stage has a measured-mean duration μ and a
//  rough envelope of ±50 % around it on the first run, tightening to
//  ±20 % once we have ≥3 samples. The ETA the user sees is
//
//      estimatedRemaining = sum(μ_remaining) − measured_since_start
//
//  When the elapsed wall-clock crosses 2× the current estimate we
//  surface "Taking longer than usual — still working" without crashing
//  the screen.
//

import Foundation

@MainActor
final class ETAEstimator {

    static let shared = ETAEstimator()

    /// Coarse stages the user-visible ETA covers. Maps onto
    /// PipelineOrchestrator.Progress / GameStatus and to the per-stage
    /// timings the orchestrator already records.
    enum Stage: String, CaseIterable, Codable {
        case stage1, stage2, ranking, compose
    }

    /// What the view should render this tick.
    struct Reading {
        /// Lower bound of "about N min". Same as upper on tight runs.
        let lowerSeconds: TimeInterval
        let upperSeconds: TimeInterval
        /// 0..1; goes negative if we're overdue (UI clamps for the bar).
        let progress: Double
        /// First-time-on-device → wide envelope.
        let isFirstRun: Bool
        /// Wall-clock has passed 2× the estimate.
        let isOverdue: Bool

        /// User-facing "about N min remaining" copy.
        var label: String {
            if isOverdue { return "Taking longer than usual — still working" }
            let lo = formatMinSec(max(0, lowerSeconds))
            let hi = formatMinSec(max(0, upperSeconds))
            if isFirstRun, lo != hi {
                return "Composing reel — about \(lo)–\(hi) remaining"
            }
            let mid = (lowerSeconds + upperSeconds) / 2
            return "Composing reel — about \(formatMinSec(max(0, mid))) remaining"
        }

        private func formatMinSec(_ s: TimeInterval) -> String {
            let sec = Int(s.rounded())
            if sec < 60 { return "\(max(5, sec)) s" }
            let m = sec / 60
            let r = sec % 60
            if r == 0 { return "\(m) min" }
            return "\(m) min \(r) s"
        }
    }

    // MARK: - Per-device, per-stage EMA

    private struct StageStats: Codable {
        var meanSeconds: Double
        var sampleCount: Int
    }

    private struct Snapshot: Codable {
        var stages: [String: StageStats] = [:]
    }

    private let defaultsKey = "playercut.eta.snapshot.v1"
    private var snapshot: Snapshot

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let loaded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.snapshot = loaded
        } else {
            self.snapshot = Snapshot()
        }
    }

    /// Records one sample of how long a stage took on this device. EMA
    /// weight rises with sample count so the first measurement
    /// dominates, then settles. Smoother than a sliding window for
    /// low-sample data.
    func recordSample(stage: Stage,
                      tier: SoCTier,
                      seconds: TimeInterval) {
        let key = Self.key(stage: stage, tier: tier)
        var stats = snapshot.stages[key]
            ?? StageStats(meanSeconds: seconds, sampleCount: 0)
        // EMA with α = 1/(n+1) → first sample sets the mean, subsequent
        // samples average in geometrically.
        let alpha = 1.0 / Double(stats.sampleCount + 1)
        stats.meanSeconds = stats.meanSeconds * (1 - alpha) + seconds * alpha
        stats.sampleCount += 1
        snapshot.stages[key] = stats
        persist()
    }

    /// Returns the user-visible reading. `startedAt` is the wall-clock
    /// moment the pipeline began (PipelineOrchestrator stores it on
    /// the GameSession via game.startedAt's processing surrogate).
    func reading(currentStage: Stage,
                 tier: SoCTier,
                 elapsed: TimeInterval) -> Reading {
        // Compute estimated time for *remaining* stages including the
        // current one (we conservatively assume the current stage has
        // only just started for the seed run).
        let allStages = Stage.allCases
        let currentIndex = allStages.firstIndex(of: currentStage) ?? 0
        let remaining = allStages.suffix(from: currentIndex)

        var lower: Double = 0
        var upper: Double = 0
        var allCold = true
        for s in remaining {
            let stats = snapshot.stages[Self.key(stage: s, tier: tier)]
            if let stats, stats.sampleCount > 0 {
                allCold = false
                let envelope: Double = stats.sampleCount >= 3 ? 0.20 : 0.50
                lower += stats.meanSeconds * (1 - envelope)
                upper += stats.meanSeconds * (1 + envelope)
            } else {
                // Cold-cache seed: very rough per-stage prior, tier-
                // aware. Tighter as tier improves.
                let seed = Self.coldStartSeed(stage: s, tier: tier)
                lower += seed * 0.5
                upper += seed * 1.5
            }
        }

        let estTotal = (lower + upper) / 2
        let remainingLo = max(0, lower - elapsed)
        let remainingHi = max(0, upper - elapsed)
        let progress = estTotal > 0 ? min(1, max(0, elapsed / estTotal)) : 0
        let overdue = elapsed > estTotal * 2 && estTotal > 0

        return Reading(lowerSeconds: remainingLo,
                       upperSeconds: remainingHi,
                       progress: progress,
                       isFirstRun: allCold,
                       isOverdue: overdue)
    }

    private static func coldStartSeed(stage: Stage, tier: SoCTier) -> Double {
        // Rough order-of-magnitude seeds per minute of source video
        // for the iPhone 13 / 14 (A15) baseline; bumped for older,
        // dropped for newer. The first real sample replaces these.
        let baseline: Double = {
            switch stage {
            case .stage1:  return 25  // optical-flow + audio sweep
            case .stage2:  return 90  // CoreML on candidates
            case .ranking: return 2
            case .compose: return 35  // MTI render + HEVC export
            }
        }()
        let scale: Double = {
            switch DeviceCapabilities.effectiveTier(tier) {
            case .a13:      return 1.6
            case .a14:      return 1.3
            case .a15:      return 1.0
            case .a16:      return 0.85
            case .a17:      return 0.70
            case .a18plus:  return 0.55
            case .unknown:  return 0.85
            }
        }()
        return baseline * scale
    }

    private static func key(stage: Stage, tier: SoCTier) -> String {
        "\(DeviceCapabilities.effectiveTier(tier).rawValue).\(stage.rawValue)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Test seam

    /// Wipes the persisted snapshot. Tests use this to exercise the
    /// cold-start path; production never calls it.
    func reset() {
        snapshot = Snapshot()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
