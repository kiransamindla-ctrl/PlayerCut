//
//  PipelineOrchestrator.swift
//  PlayerCut
//
//  Drives the end-to-end pipeline: Stage 1 → Stage 2 → Ranker → Composer.
//  Reports progress via async stream for UI; persists intermediate results
//  so the pipeline can resume if killed mid-run.
//

import Foundation
import os.log

actor PipelineOrchestrator {

    private let log = Logger(subsystem: "com.playercut.app", category: "Orchestrator")
    private let stage1 = Stage1CoarseDetector()
    private let stage2 = Stage2PlayerLocalizer()
    private let ranker = HighlightRanker()
    private let composer = ReelComposer()
    private let store: GameStore

    init(store: GameStore) {
        self.store = store
        installMemoryPressureHandler()
    }

    /// Flush pixel pools and pause Stage 2 for 30s on `.critical` memory
    /// pressure. Gives the system time to reclaim before we resume heavy
    /// per-frame work.
    private func installMemoryPressureHandler() {
        let stage1 = self.stage1
        let stage2 = self.stage2
        let log = self.log
        MemoryPressureMonitor.shared.addHandler { event in
            guard event.contains(.critical) else { return }
            log.warning("Critical memory pressure — flushing pools, pausing Stage 2 30s")
            Task {
                await stage1.flushPools()
                await stage2.flushPools()
                await stage2.pause(forSeconds: 30)
            }
        }
    }

    enum Progress: Sendable {
        case stage1Started
        case stage1Completed(candidateCount: Int)
        case stage2Started(totalWindows: Int)
        case stage2Progress(processed: Int, total: Int)
        case stage2Completed(momentCount: Int)
        case rankingCompleted(clipCount: Int)
        case composing
        case completed(reelURL: URL)
        case failed(Error)
    }

    func run(gameId: UUID,
             musicURL: URL?) -> AsyncStream<Progress> {
        AsyncStream { continuation in
            Task {
                do {
                    var game = try await self.store.game(id: gameId)
                    let player = try await self.store.player(id: game.playerId)

                    // Stage 1
                    continuation.yield(.stage1Started)
                    game.status = .stage1Running
                    try await self.store.upsert(game)

                    let stage1Result = try await self.stage1.detect(in: game)
                    game.stage1Result = stage1Result
                    try await self.store.upsert(game)
                    continuation.yield(.stage1Completed(
                        candidateCount: stage1Result.candidates.count))

                    // Stage 2
                    game.status = .stage2Running
                    try await self.store.upsert(game)
                    continuation.yield(.stage2Started(
                        totalWindows: stage1Result.candidates.count))

                    let stage2Result = try await self.stage2.localize(
                        in: game,
                        candidates: stage1Result.candidates,
                        enrollment: player)
                    game.stage2Result = stage2Result
                    try await self.store.upsert(game)
                    continuation.yield(.stage2Completed(
                        momentCount: stage2Result.moments.count))

                    // Ranking
                    let plan = self.ranker.selectClips(from: stage2Result.moments)
                    continuation.yield(.rankingCompleted(clipCount: plan.selected.count))

                    if plan.selected.count < 4 {
                        throw PipelineError.insufficientCandidates(
                            found: plan.selected.count, needed: 4)
                    }

                    // Compose
                    game.status = .composing
                    try await self.store.upsert(game)
                    continuation.yield(.composing)

                    let outputURL = StoragePaths
                        .gameDirectory(for: game.id)
                        .appendingPathComponent("reel.mp4")
                    let url = try await self.composer.compose(plan: plan,
                                                              game: game,
                                                              player: player,
                                                              musicURL: musicURL,
                                                              outputURL: outputURL)
                    game.exportedReelURL = url
                    game.status = .completed
                    try await self.store.upsert(game)

                    continuation.yield(.completed(reelURL: url))
                } catch {
                    self.log.error("Pipeline failed: \(error.localizedDescription)")
                    continuation.yield(.failed(error))
                }
                continuation.finish()
            }
        }
    }
}
