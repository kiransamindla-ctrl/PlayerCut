//
//  MusicLibrary.swift
//  PlayerCut/Music
//
//  Loads the bundled music manifest at startup, exposes a picker
//  that rotates least-recently-used tracks per (player, vibe), and
//  returns the URL + BPM the composer needs to drive beat-snapping
//  and ducking.
//
//  Per the Section-1 spec: every reel — Tier 1/2/3 + compilation —
//  must have music. A nil return here is treated as a programming
//  error (manifest missing / decode failed); the caller logs loudly
//  rather than silently shipping a silent reel.
//

import Foundation
import os.log

@MainActor
final class MusicLibrary {

    static let shared = MusicLibrary()

    /// One bundled music track. URL is resolved lazily against the
    /// main bundle (the .m4a is a Resources file from project.yml's
    /// `path: PlayerCut` sources include).
    struct Track: Equatable, Hashable {
        let id: String          // "energetic_3"
        let vibe: MusicVibe     // .energetic
        let bpm: Int            // 150
        let duration: Double    // 75.0 seconds

        var url: URL? {
            Bundle.main.url(forResource: id, withExtension: "m4a")
        }
    }

    /// All tracks parsed from manifest.json at init time. Read-only.
    let allTracks: [Track]

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "MusicLibrary")
    private let defaultsKeyPrefix = "playercut.music.lru."

    private init() {
        self.allTracks = Self.loadManifest()
        log.info("MusicLibrary loaded \(self.allTracks.count) tracks")
    }

    // MARK: - Public picker

    /// Selects a track for `playerId` + `vibe`, rotated LRU so the
    /// same player doesn't get the same track twice in a row. `length`
    /// is informational — every bundled track is 75 s and the
    /// composer loops or trims to fit the reel.
    func pick(vibe: MusicVibe,
              playerId: UUID,
              length: ReelLength) -> Track? {
        let pool = allTracks.filter { $0.vibe == vibe }
        guard !pool.isEmpty else {
            log.error("MusicLibrary.pick: no tracks for vibe \(vibe.rawValue, privacy: .public)")
            return nil
        }
        let recents = recentlyUsedIDs(for: playerId, vibe: vibe)
        // Prefer a track that's NOT in the recent set. If all tracks
        // in the pool have been used recently (i.e. fewer tracks than
        // the recent-set cap), fall back to the OLDEST recent — i.e.
        // the front of the recents array.
        let pick: Track
        if let fresh = pool.first(where: { !recents.contains($0.id) }) {
            pick = fresh
        } else if let oldestId = recents.first,
                  let recycled = pool.first(where: { $0.id == oldestId }) {
            pick = recycled
        } else {
            pick = pool.first!
        }
        recordUsage(playerId: playerId, vibe: vibe,
                    trackId: pick.id, poolSize: pool.count)
        log.info("MusicLibrary.pick \(vibe.rawValue, privacy: .public) → \(pick.id, privacy: .public) bpm=\(pick.bpm) (pool=\(pool.count))")
        return pick
    }

    /// Used by tests + diagnostics to clear all LRU state.
    func resetRotation() {
        let prefix = defaultsKeyPrefix
        let defs = UserDefaults.standard
        for key in defs.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) {
            defs.removeObject(forKey: key)
        }
    }

    // MARK: - LRU bookkeeping

    private func defaultsKey(playerId: UUID, vibe: MusicVibe) -> String {
        "\(defaultsKeyPrefix)\(playerId.uuidString).\(vibe.rawValue)"
    }

    /// Ordered list of recently-used track IDs for this (player, vibe).
    /// Oldest first → most recent last.
    private func recentlyUsedIDs(for playerId: UUID,
                                 vibe: MusicVibe) -> [String] {
        let key = defaultsKey(playerId: playerId, vibe: vibe)
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func recordUsage(playerId: UUID,
                             vibe: MusicVibe,
                             trackId: String,
                             poolSize: Int) {
        let key = defaultsKey(playerId: playerId, vibe: vibe)
        var recents = recentlyUsedIDs(for: playerId, vibe: vibe)
        recents.removeAll(where: { $0 == trackId })
        recents.append(trackId)
        // Cap recents to poolSize - 1 so we always have at least one
        // unrecent track to pick next time.
        let cap = max(1, poolSize - 1)
        if recents.count > cap {
            recents.removeFirst(recents.count - cap)
        }
        UserDefaults.standard.set(recents, forKey: key)
    }

    // MARK: - Manifest loading

    private struct ManifestTrack: Decodable {
        let id: String
        let file: String
        let vibe: String          // "Energetic" / "Cinematic" / ...
        let bpm: Int
        let duration: Double
    }

    private struct ManifestRoot: Decodable {
        let tracks: [ManifestTrack]
    }

    private static func loadManifest() -> [Track] {
        let log = Logger(subsystem: "com.playercut.app", category: "MusicLibrary")
        guard let url = Bundle.main.url(forResource: "manifest",
                                        withExtension: "json") else {
            log.error("manifest.json not found in main bundle")
            return []
        }
        guard let data = try? Data(contentsOf: url) else {
            log.error("manifest.json could not be read")
            return []
        }
        let root: ManifestRoot
        do {
            root = try JSONDecoder().decode(ManifestRoot.self, from: data)
        } catch {
            log.error("manifest decode failed: \(error.localizedDescription)")
            return []
        }
        return root.tracks.compactMap { raw -> Track? in
            guard let vibe = parseVibe(raw.vibe) else {
                log.warning("manifest track \(raw.id, privacy: .public) has unknown vibe \(raw.vibe, privacy: .public)")
                return nil
            }
            return Track(id: raw.id, vibe: vibe,
                         bpm: raw.bpm, duration: raw.duration)
        }
    }

    /// Maps the manifest's capitalised vibe strings ("Energetic", etc.)
    /// to the lowercase `MusicVibe` enum cases.
    private static func parseVibe(_ raw: String) -> MusicVibe? {
        MusicVibe(rawValue: raw.lowercased())
    }
}
