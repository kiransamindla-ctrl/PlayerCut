//
//  Storage.swift
//  PlayerCut
//
//  Storage paths plus a minimal actor-based store for games and players.
//  Production version should back this with Core Data or SwiftData; this
//  scaffold uses JSON files to keep dependencies minimal.
//

import Foundation
import os.log

enum StoragePaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Durable metadata only. Raw video and audio never live here under
    /// the zero-video-storage policy.
    static var gamesRoot: URL {
        documents.appendingPathComponent("games")
    }

    static var playersURL: URL {
        documents.appendingPathComponent("players.json")
    }

    static var queueURL: URL {
        documents.appendingPathComponent("processing_queue.json")
    }

    static func gameDirectory(for id: UUID) -> URL {
        gamesRoot.appendingPathComponent(id.uuidString)
    }

    static func gameMetadataURL(for id: UUID) -> URL {
        gameDirectory(for: id).appendingPathComponent("metadata.json")
    }

    // MARK: - Ephemeral working area (zero-video-storage policy)

    /// Volatile working area. iOS may evict files here under storage
    /// pressure. Raw video, audio loudness, and intermediate reels live
    /// here and are deleted as soon as the reel is safely in Photos.
    static var tempGamesRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("games")
    }

    static func tempGameDirectory(for id: UUID) -> URL {
        tempGamesRoot.appendingPathComponent(id.uuidString)
    }

    static func tempRawVideoURL(for id: UUID) -> URL {
        tempGameDirectory(for: id).appendingPathComponent("raw.mov")
    }

    static func tempAudioLoudnessURL(for id: UUID) -> URL {
        tempGameDirectory(for: id).appendingPathComponent("audio_loudness.json")
    }

    static func tempReelURL(for id: UUID) -> URL {
        tempGameDirectory(for: id).appendingPathComponent("reel.mp4")
    }

    /// Where we keep a reel if Photos access is denied: in the durable
    /// gameDirectory (not tmp) so a retry works after an app relaunch.
    /// Retained for back-compat with games saved before the
    /// canonical-local-reel migration.
    static func fallbackReelURL(for id: UUID) -> URL {
        gameDirectory(for: id).appendingPathComponent("reel.mp4")
    }

    // MARK: - Canonical local reel (Section A1)

    /// Durable directory for finished reels. The sandbox copy is the
    /// canonical playback source — Photos saves are a *copy*, not the
    /// source of truth. Under "Add Photos Only" we can't read the
    /// PHAsset back anyway, so the local file is non-negotiable.
    static var reelsDirectory: URL {
        documents.appendingPathComponent("reels")
    }

    /// Final on-device location of a game's reel.
    /// Documents/reels/<gameId>.mp4
    static func localReelURL(for id: UUID) -> URL {
        reelsDirectory.appendingPathComponent("\(id.uuidString).mp4")
    }
}

actor GameStore {

    private let log = Logger(subsystem: "com.playercut.app", category: "Store")

    private var players: [UUID: PlayerEnrollment] = [:]
    private var games: [UUID: GameSession] = [:]

    init() {
        try? FileManager.default.createDirectory(at: StoragePaths.gamesRoot,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: StoragePaths.reelsDirectory,
                                                 withIntermediateDirectories: true)
        loadPlayers()
        loadGames()
        pruneOldLocalReels()
    }

    /// Delete sandbox reels older than 30 days IF the user already has
    /// a copy in their Photos library. The local copy is the playback
    /// source while it exists, but Photos is the durable home; we
    /// don't need to keep both forever. // SOURCE: zero-storage policy
    /// in PlayerCut-MasterProjectMemory + Privacy footer copy.
    private func pruneOldLocalReels() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for game in games.values {
            guard game.savedToPhotos,
                  let url = game.localReelURL,
                  fm.fileExists(atPath: url.path),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
            log.info("Pruned reel \(game.id.uuidString) — >30 days old, already in Photos")
        }
    }

    // MARK: - Players

    func upsert(_ player: PlayerEnrollment) throws {
        players[player.id] = player
        try savePlayers()
    }

    func player(id: UUID) throws -> PlayerEnrollment {
        guard let p = players[id] else {
            throw PipelineError.noEnrollment
        }
        return p
    }

    func allPlayers() -> [PlayerEnrollment] {
        Array(players.values)
    }

    private func loadPlayers() {
        guard let data = try? Data(contentsOf: StoragePaths.playersURL),
              let list = try? JSONDecoder().decode([PlayerEnrollment].self, from: data)
        else { return }
        for p in list { players[p.id] = p }
    }

    private func savePlayers() throws {
        let list = Array(players.values)
        let data = try JSONEncoder().encode(list)
        try data.write(to: StoragePaths.playersURL, options: .atomic)
    }

    // MARK: - Games

    func upsert(_ game: GameSession) throws {
        games[game.id] = game
        try saveGame(game)
    }

    func game(id: UUID) throws -> GameSession {
        if let g = games[id] { return g }
        // Try to lazy-load from disk
        let url = StoragePaths.gameMetadataURL(for: id)
        let data = try Data(contentsOf: url)
        let g = try JSONDecoder().decode(GameSession.self, from: data)
        games[id] = g
        return g
    }

    func allGames() -> [GameSession] {
        Array(games.values).sorted { $0.startedAt > $1.startedAt }
    }

    private func loadGames() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: StoragePaths.gamesRoot,
            includingPropertiesForKeys: nil) else { return }

        for dir in entries {
            let metaURL = dir.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metaURL),
               let g = try? JSONDecoder().decode(GameSession.self, from: data) {
                games[g.id] = g
            }
        }
    }

    private func saveGame(_ game: GameSession) throws {
        let dir = StoragePaths.gameDirectory(for: game.id)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let url = StoragePaths.gameMetadataURL(for: game.id)
        let data = try JSONEncoder().encode(game)
        try data.write(to: url, options: .atomic)
    }
}
