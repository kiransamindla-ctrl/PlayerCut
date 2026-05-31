//
//  TemplateRegistry.swift
//  PlayerCut/Composition
//
//  Loads Resources/Templates.json at startup, indexes the 6 starting
//  templates by id, and serves the per-player default. Mirrors
//  MusicLibrary's lazy-singleton-with-Bundle.url shape so tests and
//  the app share the same load path.
//

import Foundation
import os.log

@MainActor
final class TemplateRegistry {

    static let shared = TemplateRegistry()

    /// Default template id used when neither the player nor settings
    /// have one. Beat-sync-fast is the "what most people want" pick
    /// — energetic, recognizably-edited, hard cuts on beat.
    static let defaultTemplateID = "beat-sync-fast"

    private(set) var all: [ReelTemplate] = []
    private var byID: [String: ReelTemplate] = [:]

    private let logger = Logger(subsystem: "com.playercut.app",
                                category: "TemplateRegistry")

    private init() {
        self.all = Self.loadBundled()
        self.byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        logger.info("TemplateRegistry loaded \(self.all.count) templates")
    }

    // MARK: - Lookup

    func list() -> [ReelTemplate] { all }

    func get(id: String) -> ReelTemplate? { byID[id] }

    /// Resolves the template to apply for the given player. Falls back
    /// through: player.defaultTemplateID → ReelSettings.selectedTemplateID
    /// → `defaultTemplateID` constant. The result is always non-nil as
    /// long as Templates.json decodes; nil only when the bundle is
    /// catastrophically missing.
    func resolve(playerDefaultID: String?,
                 settingsSelectedID: String?) -> ReelTemplate? {
        if let id = playerDefaultID, let t = byID[id] { return t }
        if let id = settingsSelectedID, let t = byID[id] { return t }
        return byID[Self.defaultTemplateID] ?? all.first
    }

    // MARK: - Bundle load

    private static func loadBundled() -> [ReelTemplate] {
        let logger = Logger(subsystem: "com.playercut.app",
                            category: "TemplateRegistry")
        guard let url = Bundle.main.url(forResource: "Templates",
                                        withExtension: "json") else {
            logger.error("Templates.json not in main bundle")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ReelTemplate].self, from: data)
        } catch {
            logger.error("Templates.json decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
