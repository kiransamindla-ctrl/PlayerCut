//
//  CompilationOrchestrator.swift
//  PlayerCut/Compilation
//
//  Stitches multiple per-game reels into a single end-of-season
//  compilation and saves the result to a dedicated Photos album.
//
//  NOTE on source material:
//  The per-game raw video is deleted by the zero-video-storage policy
//  as soon as the per-game reel lands in Photos. That means we *can't*
//  re-rank from the original ScoredMoment time ranges — the raw bytes
//  are gone. Instead, this orchestrator slices each game's *reel*
//  (already a curated highlight) into an equal-time chunk and
//  concatenates those chunks. The result is good enough for v1 — every
//  selected game gets a fair share of screen time and the underlying
//  per-game ranker already picked the highlights inside each chunk.
//

import AVFoundation
import Foundation
import Photos
import os.log

enum CompilationOrchestrator {

    struct Result {
        let assetId: String?    // PHAsset id when saved to Photos
        let fallbackURL: URL?   // local file when Photos denied
        var savedToPhotos: Bool { assetId != nil }
    }

    enum CompileError: Error {
        case noEligibleGames
        case exportFailed(String)
    }

    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "Compile")

    static func compose(gameIDs: [UUID],
                        store: GameStore,
                        length: CompilationLength) async throws -> Result {

        // Resolve each game's reel as an AVAsset. Prefer the PHAsset
        // (the canonical source under the storage policy); fall back to
        // the local URL if Photos was denied for that game.
        var resolved: [(GameSession, AVAsset)] = []
        for id in gameIDs {
            guard let game = try? await store.game(id: id) else { continue }
            if let assetId = game.exportedReelAssetId,
               let phAsset = PhotosLibraryService.fetchAsset(localIdentifier: assetId),
               let av = await loadAVAsset(from: phAsset) {
                resolved.append((game, av))
            } else if let url = game.localReelFallbackURL,
                      FileManager.default.fileExists(atPath: url.path) {
                resolved.append((game, AVURLAsset(url: url)))
            } else {
                log.warning("Compile: skipping \(id.uuidString) — no playable reel")
            }
        }
        guard !resolved.isEmpty else { throw CompileError.noEligibleGames }

        // Equal time per game keeps every selected match visible and is
        // simpler than re-ranking across heterogeneous sources.
        let perGame = length.targetSeconds / Double(resolved.count)
        log.info("Compile: \(resolved.count) games × \(perGame, format: .fixed(precision: 1))s")

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompileError.exportFailed("Could not add video track")
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for (game, asset) in resolved {
            let assetDuration = try await asset.load(.duration).seconds
            let take = min(assetDuration, perGame)
            let range = CMTimeRange(start: .zero,
                                    duration: CMTime(seconds: take,
                                                     preferredTimescale: 600))

            if let v = try? await asset.loadTracks(withMediaType: .video).first {
                try? videoTrack.insertTimeRange(range, of: v, at: insertTime)
            }
            if let a = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: a, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime,
                                   CMTime(seconds: take, preferredTimescale: 600))
            log.info("Compile: appended \(take, format: .fixed(precision: 1))s from game \(game.id.uuidString)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compilation-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality) else {
            throw CompileError.exportFailed("Export session init failed")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            throw CompileError.exportFailed(
                session.error?.localizedDescription ?? "Export failed")
        }
        log.info("Compile: exported \(outputURL.lastPathComponent)")

        // Land in the dedicated "PlayerCut Compilations" album.
        let saveResult = await PhotosLibraryService.saveReel(
            fileURL: outputURL,
            albumTitle: PhotosLibraryService.compilationAlbumTitle)
        await DiagnosticsStore.shared.increment(.compilationsCreated)

        switch saveResult {
        case .saved(let id):
            try? FileManager.default.removeItem(at: outputURL)
            return Result(assetId: id, fallbackURL: nil)
        case .permissionDenied:
            return Result(assetId: nil, fallbackURL: outputURL)
        }
    }

    // MARK: - Helpers

    private static func loadAVAsset(from phAsset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default()
                .requestAVAsset(forVideo: phAsset, options: opts) { asset, _, _ in
                    cont.resume(returning: asset)
                }
        }
    }
}
