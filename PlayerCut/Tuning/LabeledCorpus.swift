//
//  LabeledCorpus.swift
//  PlayerCut/Tuning
//
//  Schema and helpers for the human-labeled evaluation corpus.
//
//  USAGE:
//    1. Record 5–10 real games. Save raw .mov files plus the
//       audio_loudness.json sidecar from the capture pipeline.
//    2. For each game, sit down with a stopwatch and annotate every moment
//       a parent would want in the highlight reel. You're labeling
//       moments-the-parent-cares-about, not all the moments. Skip 50/50
//       balls and uneventful possessions.
//    3. Save annotations as JSON next to the video.
//    4. Run EvaluationHarness against the corpus. It re-runs Stage 1 and
//       Stage 2 with whatever knobs you've set, then computes precision,
//       recall, and a "parent satisfaction" score against your labels.
//

import Foundation

/// One game in the labeled corpus.
struct LabeledGame: Codable {
    let id: UUID
    let videoURL: URL
    let audioLoudnessURL: URL
    let sport: Sport
    let durationSeconds: Double
    let player: PlayerEnrollment
    let labels: [LabeledMoment]
    /// Optional notes for the labeler — e.g., "lighting was poor in second half"
    let notes: String?
}

/// A single human-annotated moment of interest.
struct LabeledMoment: Codable, Identifiable {
    let id: UUID
    /// Center time in seconds from video start.
    let centerTime: Double
    /// How important is this moment? 1 = nice-to-have, 5 = parent will be furious if missed.
    let importance: Int
    /// What kind of moment — used to slice quality metrics by event type.
    let category: Category
    /// Was the labeled player visible in this moment? (We sometimes
    /// label things that involve the player's TEAM but not the player.)
    let playerVisible: Bool
    /// Free-text description for human review.
    let description: String

    enum Category: String, Codable, CaseIterable {
        case goalOrScore       // ball goes in basket / net / endzone
        case assist            // pass that led to a score
        case defensivePlay     // block, steal, save
        case skillMove         // dribble, dodge, juke
        case sideline          // celebration, sub-in, important reaction
        case other
    }
}

extension LabeledGame {
    /// Loads a corpus directory containing one folder per game.
    /// Each folder contains: raw.mov, audio_loudness.json, labels.json
    static func loadCorpus(at directory: URL) throws -> [LabeledGame] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var games: [LabeledGame] = []
        for entry in entries {
            let labelsURL = entry.appendingPathComponent("labels.json")
            guard FileManager.default.fileExists(atPath: labelsURL.path) else {
                continue
            }
            let data = try Data(contentsOf: labelsURL)
            let game = try JSONDecoder().decode(LabeledGame.self, from: data)
            games.append(game)
        }
        return games
    }
}
