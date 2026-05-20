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
                let pipelineStart = Date()
                do {
                    var game = try await self.store.game(id: gameId)
                    let player = try await self.store.player(id: game.playerId)

                    await DiagnosticsStore.shared.recordDailyEvent(.appOpened)
                    await DiagnosticsStore.shared.recordEnum(.sport, value: game.sport)
                    await DiagnosticsStore.shared.recordEnum(
                        .reelLength,
                        value: game.reelLengthOverride ?? player.reelLengthPreference)
                    await DiagnosticsStore.shared.recordEnum(
                        .sceneType,
                        value: game.sceneType)

                    // Stage 1
                    continuation.yield(.stage1Started)
                    game.status = .stage1Running
                    try await self.store.upsert(game)

                    let stage1Start = Date()
                    let stage1Result = try await self.stage1.detect(in: game)
                    await DiagnosticsStore.shared.recordDuration(
                        .stage1,
                        seconds: Date().timeIntervalSince(stage1Start))
                    game.stage1Result = stage1Result
                    try await self.store.upsert(game)
                    continuation.yield(.stage1Completed(
                        candidateCount: stage1Result.candidates.count))

                    // Stage 2
                    game.status = .stage2Running
                    try await self.store.upsert(game)
                    continuation.yield(.stage2Started(
                        totalWindows: stage1Result.candidates.count))

                    let stage2Start = Date()
                    let stage2Result = try await self.stage2.localize(
                        in: game,
                        candidates: stage1Result.candidates,
                        enrollment: player)
                    await DiagnosticsStore.shared.recordDuration(
                        .stage2,
                        seconds: Date().timeIntervalSince(stage2Start))
                    game.stage2Result = stage2Result
                    try await self.store.upsert(game)
                    continuation.yield(.stage2Completed(
                        momentCount: stage2Result.moments.count))

                    // Resolve target reel length: per-game override beats
                    // the player's stored default.
                    let length = game.reelLengthOverride ?? player.reelLengthPreference

                    // Ranking — config preset is keyed off the reel length.
                    let rankingStart = Date()
                    let ranker = HighlightRanker(config: .for(length: length))
                    let plan = ranker.selectClips(from: stage2Result.moments)
                    await DiagnosticsStore.shared.recordDuration(
                        .ranking,
                        seconds: Date().timeIntervalSince(rankingStart))
                    continuation.yield(.rankingCompleted(clipCount: plan.selected.count))

                    // Short/solo-practice support: a single-clip reel is
                    // a valid output. Only refuse if the ranker produced
                    // literally nothing.
                    if plan.selected.isEmpty {
                        throw PipelineError.insufficientCandidates(
                            found: 0, needed: 1)
                    }
                    if plan.totalDuration < length.targetSeconds * 0.5 {
                        await DiagnosticsStore.shared.increment(.shortReelProduced)
                        self.log.info("Short reel: \(plan.totalDuration, format: .fixed(precision: 1))s vs target \(length.targetSeconds, format: .fixed(precision: 0))s")
                    }

                    // Compose
                    game.status = .composing
                    try await self.store.upsert(game)
                    continuation.yield(.composing)

                    // Reel is composed into a temp file. ReelComposer will
                    // try to land it in Photos and either return an
                    // assetId (good) or a fallback file URL (Photos denied).
                    let outputURL = StoragePaths.tempReelURL(for: game.id)
                    try? FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    let composeStart = Date()
                    let composeResult = try await self.composer.compose(
                        plan: plan,
                        game: game,
                        player: player,
                        length: length,
                        musicURL: musicURL,
                        outputURL: outputURL)
                    await DiagnosticsStore.shared.recordDuration(
                        .composition,
                        seconds: Date().timeIntervalSince(composeStart))
                    game.exportedReelAssetId = composeResult.assetId
                    game.localReelFallbackURL = composeResult.fallbackURL
                    game.status = .completed
                    try await self.store.upsert(game)

                    // Zero-video-storage policy: once the reel is in the
                    // Photos library, delete the raw recording. If we
                    // only have a local fallback (Photos denied), keep
                    // raw + audio in place so a retry is possible.
                    if composeResult.savedToPhotos {
                        await self.deleteEphemeralVideoFiles(for: game)
                    } else {
                        self.log.warning("Reel kept locally; raw video retained pending retry")
                    }

                    await DiagnosticsStore.shared.increment(.reelsCompleted)
                    await DiagnosticsStore.shared.recordDuration(
                        .totalPipeline,
                        seconds: Date().timeIntervalSince(pipelineStart))
                    // Free-trial accounting: only counts completed reels
                    // on the free plan, so paid users don't burn the
                    // counter accidentally on a refund/downgrade.
                    if PricingGate.currentPlan == .freeTrial {
                        await MainActor.run {
                            PricingGate.recordFreeReelConsumed()
                        }
                    }

                    // Surface the reel URL the UI can use right now:
                    // the in-Photos copy lives behind a PHAsset id, so
                    // we yield the fallback URL or the temp output for
                    // immediate playback. GameDetailView decides which.
                    let yieldURL = composeResult.fallbackURL ?? outputURL
                    continuation.yield(.completed(reelURL: yieldURL))
                } catch {
                    self.log.error("Pipeline failed: \(error.localizedDescription)")
                    await DiagnosticsStore.shared.increment(.reelsFailed)
                    if let pe = error as? PipelineError {
                        switch pe {
                        case .captureFailed:
                            await DiagnosticsStore.shared.increment(.errorCaptureFailed)
                        case .compositionFailed:
                            await DiagnosticsStore.shared.increment(.errorComposeFailed)
                        default:
                            await DiagnosticsStore.shared.increment(.errorPipelineFailed)
                        }
                    } else {
                        await DiagnosticsStore.shared.increment(.errorPipelineFailed)
                    }
                    continuation.yield(.failed(error))
                }
                continuation.finish()
            }
        }
    }

    /// Removes raw video + audio loudness once the reel is safely landed
    /// in the Photos library. Best-effort: if a delete fails we log and
    /// move on rather than failing the pipeline — the file lives in tmp
    /// and iOS will reclaim it under storage pressure regardless.
    private func deleteEphemeralVideoFiles(for game: GameSession) async {
        let fm = FileManager.default
        var anyDeleted = false
        for url in [game.rawVideoURL, game.audioLoudnessURL] {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    anyDeleted = true
                    log.info("Deleted ephemeral file: \(url.lastPathComponent)")
                } catch {
                    log.error("Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        // Try to clean up the per-game tmp directory if it's empty now.
        let dir = StoragePaths.tempGameDirectory(for: game.id)
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path),
           contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
        if anyDeleted {
            await DiagnosticsStore.shared.increment(.rawVideoDeleted)
        }
    }
}
