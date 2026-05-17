//
//  CoreModels.swift
//  PlayerCut
//
//  Domain types used across the capture and analysis pipeline.
//

import Foundation
import CoreGraphics
import simd

// MARK: - Enrollment

/// One-time setup data for a single child. Persisted in Core Data.
struct PlayerEnrollment: Codable, Identifiable {
    let id: UUID
    var name: String
    var jerseyNumber: String           // e.g. "23"; stored as string to handle "00"
    var jerseyColorHSV: HSVHistogram   // 32-bin H × 8-bin S histogram, normalized
    var faceEmbedding: [Float]         // 128-D from VNGenerateFaceEmbeddingRequest
    var sport: Sport
    var createdAt: Date
}

enum Sport: String, Codable {
    case soccer
    case basketball
    case pickleball
    case lacrosse
    case footballAmerican = "football_american"
}

/// HSV histogram for jersey color matching. We deliberately ignore V (brightness)
/// because field lighting changes drastically through a game.
struct HSVHistogram: Codable {
    var bins: [Float]   // length = 32 * 8 = 256, L1-normalized

    /// Chi-squared distance, lower = more similar.
    func chiSquared(to other: HSVHistogram) -> Float {
        precondition(bins.count == other.bins.count)
        var sum: Float = 0
        for i in 0..<bins.count {
            let a = bins[i]
            let b = other.bins[i]
            let denom = a + b
            if denom > 0 {
                sum += ((a - b) * (a - b)) / denom
            }
        }
        return sum * 0.5
    }
}

// MARK: - Game session

/// Top-level record for one recorded game.
struct GameSession: Codable, Identifiable {
    let id: UUID
    let playerId: UUID
    let sport: Sport
    let startedAt: Date
    var endedAt: Date?
    var rawVideoURL: URL
    var audioLoudnessURL: URL
    var stage1Result: Stage1Result?
    var stage2Result: Stage2Result?
    var exportedReelURL: URL?
    var status: GameStatus = .recording
}

enum GameStatus: String, Codable {
    case recording
    case awaitingProcessing
    case stage1Running
    case stage2Running
    case composing
    case completed
    case failed
}

// MARK: - Stage outputs

/// A candidate moment surfaced by cheap signals. Time is in seconds from video start.
struct CandidateWindow: Codable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    var audioScore: Float       // 0..1
    var motionScore: Float      // 0..1

    var duration: Double { endTime - startTime }
}

struct Stage1Result: Codable {
    var candidates: [CandidateWindow]
    var processingDuration: TimeInterval
}

/// One scored, identified moment from Stage 2.
struct ScoredMoment: Codable, Identifiable {
    let id: UUID
    var window: CandidateWindow
    var identificationConfidence: Float    // 0..1
    var activityScore: Float               // 0..1
    var playerBoundingBoxes: [TimedBox]    // for 9:16 reframing
    var compositeScore: Float
}

struct TimedBox: Codable {
    let time: Double            // seconds from video start
    let box: CGRect             // normalized 0..1 in video frame
}

struct Stage2Result: Codable {
    var moments: [ScoredMoment]
    var processingDuration: TimeInterval
}

// MARK: - Errors

enum PipelineError: Error {
    case captureFailed(String)
    case stage1Failed(String)
    case stage2Failed(String)
    case compositionFailed(String)
    case noEnrollment
    case insufficientCandidates(found: Int, needed: Int)
}
