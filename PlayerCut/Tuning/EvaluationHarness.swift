//
//  EvaluationHarness.swift
//  PlayerCut/Tuning
//
//  Runs the pipeline against the labeled corpus and reports quality metrics.
//  Supports parameter sweeps so you can find the right thresholds empirically
//  instead of guessing.
//
//  Run via a debug-only menu in the app, or as an XCTest target. Producing
//  the final reel is optional — for tuning, you usually only care about
//  Stage 1 / Stage 2 / Ranker outputs.
//

import Foundation
import os.log

struct EvalConfig: Codable, Hashable {
    var audioSigmaThreshold: Float = 2.0
    var flowSigmaThreshold: Float = 2.0
    var identificationThreshold: Float = 0.55
    var rankerMinSeparation: Double = 30.0
    var rankerTargetDuration: Double = 60.0

    /// Toleration window for matching detected moments to labeled ones.
    /// A detected window that overlaps within ±tolerance of a label's
    /// centerTime counts as a true positive.
    var matchToleranceSeconds: Double = 5.0
}

/// Per-game evaluation result.
struct GameEvalResult {
    let gameID: UUID
    let config: EvalConfig

    // Stage 1 quality (cheap detector)
    let stage1Recall: Float
    let stage1Precision: Float
    let stage1CandidateCount: Int

    // Stage 2 quality (after identification)
    let stage2Recall: Float
    let stage2Precision: Float
    let stage2MomentCount: Int

    // Final reel quality
    let reelRecall: Float                // % of labels picked
    let reelImportanceWeightedRecall: Float  // weighted by importance score
    let reelClipCount: Int
    let parentSatisfactionScore: Float   // composite, 0..1

    let stage1Duration: TimeInterval
    let stage2Duration: TimeInterval
}

/// Aggregated result across the corpus.
struct CorpusEvalResult {
    let config: EvalConfig
    let perGame: [GameEvalResult]

    var avgStage1Recall: Float {
        average(perGame.map { $0.stage1Recall })
    }
    var avgStage2Recall: Float {
        average(perGame.map { $0.stage2Recall })
    }
    var avgReelRecall: Float {
        average(perGame.map { $0.reelRecall })
    }
    var avgImportanceWeightedRecall: Float {
        average(perGame.map { $0.reelImportanceWeightedRecall })
    }
    var avgParentSatisfaction: Float {
        average(perGame.map { $0.parentSatisfactionScore })
    }

    private func average(_ xs: [Float]) -> Float {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Float(xs.count)
    }
}

actor EvaluationHarness {

    private let log = Logger(subsystem: "com.playercut.app", category: "Eval")

    // MARK: - Single-config evaluation

    func evaluate(corpus: [LabeledGame],
                  config: EvalConfig) async -> CorpusEvalResult {
        var results: [GameEvalResult] = []
        for game in corpus {
            do {
                let result = try await evaluateGame(game: game, config: config)
                results.append(result)
                log.info("""
                    Game \(game.id.uuidString): \
                    s1Recall=\(result.stage1Recall), \
                    s2Recall=\(result.stage2Recall), \
                    reelRecall=\(result.reelRecall)
                    """)
            } catch {
                log.error("Eval failed for game \(game.id.uuidString): \(error.localizedDescription)")
            }
        }
        return CorpusEvalResult(config: config, perGame: results)
    }

    private func evaluateGame(game: LabeledGame,
                              config: EvalConfig) async throws -> GameEvalResult {
        // Build a transient GameSession to feed the existing actors.
        let session = GameSession(
            id: game.id,
            playerId: game.player.id,
            sport: game.sport,
            startedAt: Date(),
            endedAt: Date(),
            rawVideoURL: game.videoURL,
            audioLoudnessURL: game.audioLoudnessURL,
            stage1Result: nil,
            stage2Result: nil,
            exportedReelAssetId: nil,
            localReelFallbackURL: nil,
            status: .awaitingProcessing
        )

        // Configure stages with the test config. (In a production tuning
        // build, expose these as init parameters on Stage 1 / Stage 2.)
        let stage1 = Stage1CoarseDetector()
        let stage2 = Stage2PlayerLocalizer()
        let ranker = HighlightRanker(config: RankerConfig(
            targetTotalDuration: config.rankerTargetDuration,
            minClipDuration: 4,
            maxClipDuration: 6,
            hardMaxClipDuration: 8,
            minSeparation: config.rankerMinSeparation,
            minClips: 8,
            maxClips: 14,
            exceptionalScoreThreshold: 0.85
        ))

        let s1Start = Date()
        let s1 = try await stage1.detect(in: session)
        let s1Duration = Date().timeIntervalSince(s1Start)

        let s2Start = Date()
        let s2 = try await stage2.localize(in: session,
                                           candidates: s1.candidates,
                                           enrollment: game.player)
        let s2Duration = Date().timeIntervalSince(s2Start)

        let plan = ranker.selectClips(from: s2.moments)

        // Compute metrics
        let s1Metrics = matchMetrics(
            detected: s1.candidates.map { ($0.startTime + $0.endTime) / 2 },
            labels: game.labels,
            tolerance: config.matchToleranceSeconds)

        let s2Metrics = matchMetrics(
            detected: s2.moments.map { ($0.window.startTime + $0.window.endTime) / 2 },
            labels: game.labels,
            tolerance: config.matchToleranceSeconds)

        let reelTimes = plan.selected.map { ($0.clipStart + $0.clipEnd) / 2 }
        let reelMetrics = matchMetrics(
            detected: reelTimes,
            labels: game.labels,
            tolerance: config.matchToleranceSeconds)

        // Importance-weighted recall: each label's contribution scales with
        // its importance (1..5). Useful because missing one importance-5
        // moment is disastrous; missing three importance-1 moments is fine.
        let importanceWeighted = importanceWeightedRecall(
            detected: reelTimes,
            labels: game.labels,
            tolerance: config.matchToleranceSeconds
        )

        // Parent satisfaction = composite tuned to match real parent
        // feedback patterns. Heavy emphasis on importance-weighted recall
        // (missing the goal is unforgivable) plus a light penalty for
        // including obvious junk (low precision = boring reel).
        let clipCountTerm: Float = Float(min(plan.selected.count, 12)) / 12.0
        let satisfaction: Float =
            0.7 * importanceWeighted
            + 0.2 * reelMetrics.precision
            + 0.1 * clipCountTerm

        return GameEvalResult(
            gameID: game.id,
            config: config,
            stage1Recall: s1Metrics.recall,
            stage1Precision: s1Metrics.precision,
            stage1CandidateCount: s1.candidates.count,
            stage2Recall: s2Metrics.recall,
            stage2Precision: s2Metrics.precision,
            stage2MomentCount: s2.moments.count,
            reelRecall: reelMetrics.recall,
            reelImportanceWeightedRecall: importanceWeighted,
            reelClipCount: plan.selected.count,
            parentSatisfactionScore: satisfaction,
            stage1Duration: s1Duration,
            stage2Duration: s2Duration
        )
    }

    // MARK: - Sweep

    /// Grid-sweep over a parameter space. Returns results sorted by parent
    /// satisfaction score, descending.
    func sweep(corpus: [LabeledGame],
               sigmas: [Float],
               idThresholds: [Float]) async -> [CorpusEvalResult] {

        var configs: [EvalConfig] = []
        for sigma in sigmas {
            for id in idThresholds {
                var c = EvalConfig()
                c.audioSigmaThreshold = sigma
                c.flowSigmaThreshold = sigma
                c.identificationThreshold = id
                configs.append(c)
            }
        }

        var allResults: [CorpusEvalResult] = []
        for c in configs {
            let result = await evaluate(corpus: corpus, config: c)
            allResults.append(result)
            log.info("""
                Config sigma=\(c.audioSigmaThreshold), id=\(c.identificationThreshold) \
                → satisfaction=\(result.avgParentSatisfaction)
                """)
        }
        return allResults.sorted { $0.avgParentSatisfaction > $1.avgParentSatisfaction }
    }

    // MARK: - Metrics primitives

    private struct PRMetrics {
        let recall: Float
        let precision: Float
    }

    private func matchMetrics(detected: [Double],
                              labels: [LabeledMoment],
                              tolerance: Double) -> PRMetrics {
        guard !labels.isEmpty else {
            return PRMetrics(recall: 1, precision: detected.isEmpty ? 1 : 0)
        }
        var labelHit = Array(repeating: false, count: labels.count)
        var detectedHit = Array(repeating: false, count: detected.count)

        for (di, det) in detected.enumerated() {
            for (li, label) in labels.enumerated() {
                if labelHit[li] { continue }
                if abs(det - label.centerTime) <= tolerance {
                    labelHit[li] = true
                    detectedHit[di] = true
                    break
                }
            }
        }

        let recall = Float(labelHit.filter { $0 }.count) / Float(labels.count)
        let precision = detected.isEmpty
            ? 0
            : Float(detectedHit.filter { $0 }.count) / Float(detected.count)
        return PRMetrics(recall: recall, precision: precision)
    }

    private func importanceWeightedRecall(detected: [Double],
                                          labels: [LabeledMoment],
                                          tolerance: Double) -> Float {
        guard !labels.isEmpty else { return 1 }
        let totalImportance = Float(labels.reduce(0) { $0 + $1.importance })
        var matchedImportance: Float = 0

        for label in labels {
            let matched = detected.contains { abs($0 - label.centerTime) <= tolerance }
            if matched {
                matchedImportance += Float(label.importance)
            }
        }
        return matchedImportance / totalImportance
    }
}

// MARK: - CLI-style report renderer

extension CorpusEvalResult {
    func report() -> String {
        let lines = [
            "=" * 60,
            "EVAL REPORT — config: σ=\(config.audioSigmaThreshold) idTh=\(config.identificationThreshold)",
            "=" * 60,
            "Games evaluated: \(perGame.count)",
            "",
            String(format: "Stage 1 recall:    %.1f%%", avgStage1Recall * 100),
            String(format: "Stage 2 recall:    %.1f%%", avgStage2Recall * 100),
            String(format: "Reel recall:       %.1f%%", avgReelRecall * 100),
            String(format: "Importance-wgt:    %.1f%%", avgImportanceWeightedRecall * 100),
            String(format: "Parent satisfact:  %.1f%%", avgParentSatisfaction * 100),
            "",
            "Per-game:",
        ] + perGame.map { r in
            String(format: "  %@: reel=%.0f%% impWgt=%.0f%% sat=%.0f%%",
                   String(r.gameID.uuidString.prefix(8)),
                   r.reelRecall * 100,
                   r.reelImportanceWeightedRecall * 100,
                   r.parentSatisfactionScore * 100)
        }
        return lines.joined(separator: "\n")
    }
}

private func *(s: String, n: Int) -> String {
    String(repeating: s, count: n)
}
