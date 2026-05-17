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
}

actor GameStore {

    private let log = Logger(subsystem: "com.playercut.app", category: "Store")

    private var players: [UUID: PlayerEnrollment] = [:]
    private var games: [UUID: GameSession] = [:]

    init() {
        try? FileManager.default.createDirectory(at: StoragePaths.gamesRoot,
                                                 withIntermediateDirectories: true)
        loadPlayers()
        loadGames()
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
