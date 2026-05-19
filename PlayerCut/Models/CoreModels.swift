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
    var reelLengthPreference: ReelLength = .sixtySeconds

    init(id: UUID,
         name: String,
         jerseyNumber: String,
         jerseyColorHSV: HSVHistogram,
         faceEmbedding: [Float],
         sport: Sport,
         createdAt: Date,
         reelLengthPreference: ReelLength = .sixtySeconds) {
        self.id = id
        self.name = name
        self.jerseyNumber = jerseyNumber
        self.jerseyColorHSV = jerseyColorHSV
        self.faceEmbedding = faceEmbedding
        self.sport = sport
        self.createdAt = createdAt
        self.reelLengthPreference = reelLengthPreference
    }

    // Back-compat decode for players enrolled before reelLengthPreference
    // existed — they fall back to the 60s default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        jerseyNumber = try c.decode(String.self, forKey: .jerseyNumber)
        jerseyColorHSV = try c.decode(HSVHistogram.self, forKey: .jerseyColorHSV)
        faceEmbedding = try c.decode([Float].self, forKey: .faceEmbedding)
        sport = try c.decode(Sport.self, forKey: .sport)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        reelLengthPreference = try c.decodeIfPresent(ReelLength.self,
                                                     forKey: .reelLengthPreference) ?? .sixtySeconds
    }
}

/// User-selectable target length of the final highlight reel.
enum ReelLength: String, CaseIterable, Codable {
    case sixtySeconds = "60s"
    case twoMinutes = "2min"
    case threeMinutes = "3min"
    case fiveMinutes = "5min"

    var targetSeconds: Double {
        switch self {
        case .sixtySeconds: return 60
        case .twoMinutes:   return 120
        case .threeMinutes: return 180
        case .fiveMinutes:  return 300
        }
    }

    var displayName: String {
        switch self {
        case .sixtySeconds: return "60 sec"
        case .twoMinutes:   return "2 min"
        case .threeMinutes: return "3 min"
        case .fiveMinutes:  return "5 min"
        }
    }
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

/// What kicked off the recording. Used for diagnostics and (later) for
/// surfacing why a game was captured when reviewing the library.
enum TriggerSource: String, Codable {
    case manual
    case mountDetected
    case calendarPreSchedule
}

/// Coarse capture environment — chosen at recording start from a
/// one-shot scene-luminance sample. Drives camera white-balance lock
/// choice (indoor fluorescent vs outdoor daylight).
enum SceneType: String, Codable {
    case indoor
    case outdoor
}

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
    /// PHAsset.localIdentifier of the reel saved into the user's Photos
    /// library. nil before the reel is saved, or if Photos access was
    /// denied (in which case `localReelFallbackURL` holds the file
    /// locally until the user retries).
    var exportedReelAssetId: String?
    /// Set only when Photos save failed (typically permission denied).
    /// File lives in the durable game directory so it survives across
    /// launches and can be re-uploaded via the GameDetailView retry path.
    var localReelFallbackURL: URL?
    var status: GameStatus = .recording
    var triggerSource: TriggerSource = .manual
    /// nil → use the player's `reelLengthPreference`. Set per-game from
    /// the capture UI so users can override without changing their default.
    var reelLengthOverride: ReelLength?
    var sceneType: SceneType = .outdoor

    init(id: UUID,
         playerId: UUID,
         sport: Sport,
         startedAt: Date,
         endedAt: Date?,
         rawVideoURL: URL,
         audioLoudnessURL: URL,
         stage1Result: Stage1Result?,
         stage2Result: Stage2Result?,
         exportedReelAssetId: String? = nil,
         localReelFallbackURL: URL? = nil,
         status: GameStatus = .recording,
         triggerSource: TriggerSource = .manual,
         reelLengthOverride: ReelLength? = nil,
         sceneType: SceneType = .outdoor) {
        self.id = id
        self.playerId = playerId
        self.sport = sport
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawVideoURL = rawVideoURL
        self.audioLoudnessURL = audioLoudnessURL
        self.stage1Result = stage1Result
        self.stage2Result = stage2Result
        self.exportedReelAssetId = exportedReelAssetId
        self.localReelFallbackURL = localReelFallbackURL
        self.status = status
        self.triggerSource = triggerSource
        self.reelLengthOverride = reelLengthOverride
        self.sceneType = sceneType
    }

    // Custom decode for back-compat across schema migrations:
    //   - exportedReelURL (pre-PHAsset) → ignored; assetId defaults nil
    //   - triggerSource / reelLengthOverride / sceneType defaults if absent
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        playerId = try c.decode(UUID.self, forKey: .playerId)
        sport = try c.decode(Sport.self, forKey: .sport)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        rawVideoURL = try c.decode(URL.self, forKey: .rawVideoURL)
        audioLoudnessURL = try c.decode(URL.self, forKey: .audioLoudnessURL)
        stage1Result = try c.decodeIfPresent(Stage1Result.self, forKey: .stage1Result)
        stage2Result = try c.decodeIfPresent(Stage2Result.self, forKey: .stage2Result)
        exportedReelAssetId = try c.decodeIfPresent(String.self, forKey: .exportedReelAssetId)
        localReelFallbackURL = try c.decodeIfPresent(URL.self, forKey: .localReelFallbackURL)
        status = try c.decodeIfPresent(GameStatus.self, forKey: .status) ?? .recording
        triggerSource = try c.decodeIfPresent(TriggerSource.self, forKey: .triggerSource) ?? .manual
        reelLengthOverride = try c.decodeIfPresent(ReelLength.self, forKey: .reelLengthOverride)
        sceneType = try c.decodeIfPresent(SceneType.self, forKey: .sceneType) ?? .outdoor
    }
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
