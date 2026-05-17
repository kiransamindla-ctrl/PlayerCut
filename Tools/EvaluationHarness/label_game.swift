#!/usr/bin/env swift
//
//  label_game.swift
//  PlayerCut/Tools/EvaluationHarness
//
//  Quick CLI helper for labeling a game. Lets you watch a video in QuickTime
//  next to this terminal, type timestamp + importance + category, and writes
//  a labels.json compatible with LabeledCorpus.
//
//  Usage:
//    swift label_game.swift /path/to/game-folder
//
//  Inside the loop:
//    Enter at "Time": HH:MM:SS or seconds
//    Importance: 1–5
//    Category: g (goal), a (assist), d (defense), s (skill), k (sideline), o (other)
//    Player visible: y/n
//    Description: free text
//    Type "done" at the time prompt to finish.
//

import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("Usage: label_game.swift <game-folder>")
    exit(1)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let labelsURL = folder.appendingPathComponent("labels.json")

struct CLIMoment: Codable {
    let id: UUID
    let centerTime: Double
    let importance: Int
    let category: String
    let playerVisible: Bool
    let description: String
}

struct CLIGame: Codable {
    let id: UUID
    let videoURL: URL
    let audioLoudnessURL: URL
    let sport: String
    let durationSeconds: Double
    let player: PlayerStub
    var labels: [CLIMoment]
    let notes: String?

    struct PlayerStub: Codable {
        let id: UUID
        let name: String
        let jerseyNumber: String
        let jerseyColorName: String
    }
}

func parseTime(_ s: String) -> Double? {
    if let direct = Double(s) { return direct }
    let parts = s.split(separator: ":").compactMap { Double($0) }
    switch parts.count {
    case 2: return parts[0] * 60 + parts[1]
    case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
    default: return nil
    }
}

func categoryCode(_ c: String) -> String? {
    switch c.lowercased().first {
    case "g": return "goalOrScore"
    case "a": return "assist"
    case "d": return "defensivePlay"
    case "s": return "skillMove"
    case "k": return "sideline"
    case "o": return "other"
    default: return nil
    }
}

print("Labeling game in: \(folder.path)")
print("Type 'done' at any time prompt to save and exit.\n")

print("Sport (soccer/basketball/pickleball/lacrosse/football_american): ", terminator: "")
let sport = readLine() ?? "soccer"

print("Game duration in seconds: ", terminator: "")
let duration = Double(readLine() ?? "5400") ?? 5400

print("Player name: ", terminator: "")
let playerName = readLine() ?? "Test"
print("Jersey number: ", terminator: "")
let jersey = readLine() ?? "10"
print("Jersey color (e.g. red, blue): ", terminator: "")
let jerseyColor = readLine() ?? "blue"

var moments: [CLIMoment] = []

while true {
    print("\nTime: ", terminator: "")
    let timeStr = readLine() ?? ""
    if timeStr.lowercased() == "done" { break }
    guard let t = parseTime(timeStr) else { print("(bad format)"); continue }

    print("Importance (1–5): ", terminator: "")
    let imp = Int(readLine() ?? "3") ?? 3

    print("Category (g/a/d/s/k/o): ", terminator: "")
    guard let cat = categoryCode(readLine() ?? "o") else { print("(bad)"); continue }

    print("Player visible? (y/n): ", terminator: "")
    let visible = (readLine() ?? "y").lowercased().first == "y"

    print("Description: ", terminator: "")
    let desc = readLine() ?? ""

    moments.append(CLIMoment(id: UUID(), centerTime: t,
                             importance: max(1, min(5, imp)),
                             category: cat,
                             playerVisible: visible,
                             description: desc))
    print("  → recorded (\(moments.count) total)")
}

let videoURL = folder.appendingPathComponent("raw.mov")
let audioURL = folder.appendingPathComponent("audio_loudness.json")

let game = CLIGame(
    id: UUID(),
    videoURL: videoURL,
    audioLoudnessURL: audioURL,
    sport: sport,
    durationSeconds: duration,
    player: .init(id: UUID(),
                  name: playerName,
                  jerseyNumber: jersey,
                  jerseyColorName: jerseyColor),
    labels: moments,
    notes: nil
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(game)
try data.write(to: labelsURL, options: .atomic)
print("\nSaved \(moments.count) moments to \(labelsURL.path)")
