//
//  PipelineOrchestrator.swift
//  PlayerCut
//
//  Drives the end-to-end pipeline: Stage 1 → Stage 2 → Ranker → Composer.
//  Reports progress via async stream for UI; persists intermediate results
//  so the pipeline can resume if killed mid-run.
//

import AVFoundation
import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

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

                // B4: take a background-task assertion so a brief
                // user-initiated app switch doesn't immediately kill
                // composing. The system grants ~30s minimum on any
                // device; we end the assertion when the pipeline
                // finishes (success or failure) or when the system
                // signals expiration.
                #if canImport(UIKit)
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = await UIApplication.shared.beginBackgroundTask(
                    withName: "playercut.pipeline.\(gameId.uuidString)") {
                    // Expiration handler — must end the task we got.
                    Task { @MainActor in
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }
                }
                defer {
                    Task { @MainActor in
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                        }
                    }
                }
                #endif
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

                    // Load source video duration so the ranker can fall
                    // back to a Tier-3 montage when no candidates survive.
                    let videoDuration = (try? await AVURLAsset(
                        url: game.rawVideoURL).load(.duration).seconds) ?? 0

                    // Ranking — config preset is keyed off the reel length,
                    // weights are sport-tuned.
                    let rankingStart = Date()
                    let ranker = HighlightRanker(
                        config: .for(length: length),
                        weights: .profile(for: player.sport))
                    let plan = ranker.selectClips(
                        from: stage2Result.moments,
                        videoDuration: videoDuration)
                    await DiagnosticsStore.shared.recordDuration(
                        .ranking,
                        seconds: Date().timeIntervalSince(rankingStart))
                    continuation.yield(.rankingCompleted(clipCount: plan.selected.count))

                    // Never-reject contract: the ranker's three tiers
                    // guarantee a non-empty plan as long as the source
                    // video has a positive duration. We log the tier so
                    // the labeled-corpus sweep can later measure how
                    // often each fallback fires in the wild.
                    game.rankerTierUsed = plan.tier
                    switch plan.tier {
                    case .normal:
                        await DiagnosticsStore.shared.increment(.rankerTier1Used)
                    case .weakSignals:
                        await DiagnosticsStore.shared.increment(.rankerTier2Used)
                    case .montageFallback:
                        await DiagnosticsStore.shared.increment(.rankerTier3Used)
                    }
                    if plan.totalDuration < length.targetSeconds * 0.5 {
                        await DiagnosticsStore.shared.increment(.shortReelProduced)
                        self.log.info("Short reel: \(plan.totalDuration, format: .fixed(precision: 1))s vs target \(length.targetSeconds, format: .fixed(precision: 0))s")
                    }

                    // Compose
                    game.status = .composing
                    try await self.store.upsert(game)
                    continuation.yield(.composing)

                    // Reel renders directly into the canonical local
                    // path (Documents/reels/<id>.mp4). That file is the
                    // playback source regardless of Photos permission.
                    let outputURL = StoragePaths.localReelURL(for: game.id)
                    try? FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)

                    // Build the cinematic EditPlan from the ranker's
                    // clip selection. Style derives from the player's
                    // musicVibe; the perf profile downgrades transition
                    // complexity and crop keyframe density on weaker
                    // hardware or under thermal pressure.
                    let aspect = game.outputAspectOverride ?? player.outputAspect
                    let renderSize = aspect.renderSize(forLength: length)
                    let output = OutputSpec(size: renderSize, fps: 30)
                    let style = EditStyle.defaultFor(
                        musicVibe: player.musicVibe)
                    let perfProfile = await DeviceClass.shared.editProfile()
                    let planBuildStart = Date()
                    let builder = EditPlanBuilder(
                        style: style,
                        output: output,
                        sourceDuration: videoDuration,
                        profile: perfProfile)
                    let editPlan = builder.build(
                        from: plan,
                        player: player,
                        game: game,
                        musicURL: musicURL,
                        musicBPM: nil)
                    await DiagnosticsStore.shared.recordDuration(
                        .composePlan,
                        seconds: Date().timeIntervalSince(planBuildStart))

                    let composeStart = Date()
                    let composeResult = try await self.composer.compose(
                        plan: editPlan,
                        game: game,
                        player: player,
                        outputURL: outputURL)
                    let composeWall = Date().timeIntervalSince(composeStart)
                    await DiagnosticsStore.shared.recordDuration(
                        .composition,
                        seconds: composeWall)
                    await DiagnosticsStore.shared.recordDuration(
                        .composeExport,
                        seconds: composeWall)
                    game.localReelURL = composeResult.localURL
                    game.savedToPhotos = composeResult.savedToPhotos
                    game.exportedReelAssetId = composeResult.assetId
                    game.localReelFallbackURL = nil  // legacy field — no longer used
                    game.status = .completed
                    try await self.store.upsert(game)

                    // Zero-raw-storage policy: the local *reel* stays
                    // in Documents/reels/ as the canonical playback
                    // source. The raw recording is always deleted —
                    // the reel doesn't need it anymore, and the user
                    // can re-share from the local copy or Photos.
                    await self.deleteEphemeralVideoFiles(for: game)
                    if !composeResult.savedToPhotos {
                        await DiagnosticsStore.shared.increment(.reelKeptLocalOnly)
                        self.log.warning("Reel kept local-only (Photos denied or failed)")
                    }

                    await DiagnosticsStore.shared.increment(.reelsCompleted)
                    // Invariant: should match reelsCompleted 1:1 under
                    // the never-reject contract. Any divergence is a
                    // regression to investigate.
                    await DiagnosticsStore.shared.increment(.reelAlwaysProduced)
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

                    // The canonical local file is what the UI plays.
                    continuation.yield(.completed(reelURL: composeResult.localURL))
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
