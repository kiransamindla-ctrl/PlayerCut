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
    var outputAspect: OutputAspect = .vertical9x16
    var musicVibe: MusicVibe = .energetic
    /// Optional beacon identifier (iBeacon major+minor packed in the
    /// UUID's last bytes). Populated by the optional "Pair beacon"
    /// enrollment step. When present, Stage 2 may skip the OCR/color/
    /// face stack on frames where the beacon is in-range.
    var beaconID: String? = nil

    init(id: UUID,
         name: String,
         jerseyNumber: String,
         jerseyColorHSV: HSVHistogram,
         faceEmbedding: [Float],
         sport: Sport,
         createdAt: Date,
         reelLengthPreference: ReelLength = .sixtySeconds,
         outputAspect: OutputAspect = .vertical9x16,
         musicVibe: MusicVibe = .energetic,
         beaconID: String? = nil) {
        self.id = id
        self.name = name
        self.jerseyNumber = jerseyNumber
        self.jerseyColorHSV = jerseyColorHSV
        self.faceEmbedding = faceEmbedding
        self.sport = sport
        self.createdAt = createdAt
        self.reelLengthPreference = reelLengthPreference
        self.outputAspect = outputAspect
        self.musicVibe = musicVibe
        self.beaconID = beaconID
    }

    // Back-compat decode for players enrolled before reelLengthPreference /
    // outputAspect / musicVibe / beaconID existed — they fall back to the
    // documented defaults.
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
        outputAspect = try c.decodeIfPresent(OutputAspect.self,
                                             forKey: .outputAspect) ?? .vertical9x16
        musicVibe = try c.decodeIfPresent(MusicVibe.self,
                                          forKey: .musicVibe) ?? .energetic
        beaconID = try c.decodeIfPresent(String.self, forKey: .beaconID)
    }
}

/// Target length for an end-of-season compilation stitched from
/// multiple games. Distinct from `ReelLength` because compilations
/// don't offer 60 s (too short to give every game a fair window) and
/// they extend up to 10 min.
enum CompilationLength: String, CaseIterable, Codable {
    case twoMinutes   = "2min"
    case threeMinutes = "3min"
    case fiveMinutes  = "5min"
    case tenMinutes   = "10min"

    var targetSeconds: Double {
        switch self {
        case .twoMinutes:   return 120
        case .threeMinutes: return 180
        case .fiveMinutes:  return 300
        case .tenMinutes:   return 600
        }
    }

    var displayName: String {
        switch self {
        case .twoMinutes:   return "2 min"
        case .threeMinutes: return "3 min"
        case .fiveMinutes:  return "5 min"
        case .tenMinutes:   return "10 min"
        }
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

/// Output aspect ratio for the final reel. Defaults to vertical for
/// social-feed friendly sharing. ReelComposer crops based on the
/// tracked-player center.
enum OutputAspect: String, Codable, CaseIterable {
    case vertical9x16
    case horizontal16x9
    case square1x1

    var displayName: String {
        switch self {
        case .vertical9x16:   return "9:16 Vertical"
        case .horizontal16x9: return "16:9 Horizontal"
        case .square1x1:      return "1:1 Square"
        }
    }

    /// Pill-style short label for the capture-screen aspect chip.
    var pillLabel: String {
        switch self {
        case .vertical9x16:   return "9:16"
        case .horizontal16x9: return "16:9"
        case .square1x1:      return "1:1"
        }
    }

    func renderSize(forLength length: ReelLength) -> CGSize {
        // ≤3 min reels render at the higher resolution; 5-minute reels
        // drop to 720-class so the MP4 stays share-friendly.
        let high = length != .fiveMinutes
        switch self {
        case .vertical9x16:
            return high ? CGSize(width: 1080, height: 1920)
                        : CGSize(width: 720,  height: 1280)
        case .horizontal16x9:
            return high ? CGSize(width: 1920, height: 1080)
                        : CGSize(width: 1280, height: 720)
        case .square1x1:
            return high ? CGSize(width: 1080, height: 1080)
                        : CGSize(width: 720,  height: 720)
        }
    }
}

/// Music feel applied by the composer when picking from the bundled
/// library (or when scoring user-imported tracks). Stored on the
/// player so it doesn't have to be chosen per-game.
enum MusicVibe: String, Codable, CaseIterable {
    case energetic
    case cinematic
    case playful
    case chill

    var displayName: String {
        switch self {
        case .energetic: return "Energetic"
        case .cinematic: return "Cinematic"
        case .playful:   return "Playful"
        case .chill:     return "Chill"
        }
    }
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
    /// Canonical local copy of the finished reel. Stored on disk as a
    /// relative path (e.g. "reels/<id>.mp4") under Documents/ and
    /// rebuilt against the *current* Documents URL on every decode.
    /// iOS rewrites the container UUID on reinstall (and across some
    /// upgrades), so an absolute URL captured at write time can no
    /// longer be resolved at read time — the relative form is the
    /// only durable representation.
    /// The in-memory value is always an absolute URL pointing into
    /// the current container.
    var localReelURL: URL?
    /// True when a *copy* of the reel was successfully added to the
    /// user's Photos library (Recents at minimum, optionally also the
    /// PlayerCut album under full access).
    var savedToPhotos: Bool = false
    /// PHAsset.localIdentifier of the reel saved into the user's Photos
    /// library. Set only when we ran under full-access AND were able
    /// to read it back. Under add-only / limited this stays nil — the
    /// reel still lives in Photos Recents and on the local sandbox.
    var exportedReelAssetId: String?
    /// Retained for back-compat decode of pre-canonical-local games.
    /// New code should use `localReelURL` instead.
    var localReelFallbackURL: URL?
    var status: GameStatus = .recording
    var triggerSource: TriggerSource = .manual
    /// nil → use the player's `reelLengthPreference`. Set per-game from
    /// the capture UI so users can override without changing their default.
    var reelLengthOverride: ReelLength?
    var sceneType: SceneType = .outdoor
    /// nil → use the player's `outputAspect`. Per-game override.
    var outputAspectOverride: OutputAspect?
    /// Which ranker tier produced this game's reel. nil until the
    /// pipeline reaches the ranker.
    var rankerTierUsed: RankerTier?
    /// Recipe actually applied at capture start. Composer reads this
    /// to know the source resolution (reframe headroom) and the source
    /// fps (real 0.5x slow-mo vs. frame-blended). nil for games
    /// recorded before the adaptive-capture migration — composer
    /// treats nil as "assume 1080p30, no real slow-mo".
    var captureRecipe: CaptureRecipe?

    init(id: UUID,
         playerId: UUID,
         sport: Sport,
         startedAt: Date,
         endedAt: Date?,
         rawVideoURL: URL,
         audioLoudnessURL: URL,
         stage1Result: Stage1Result?,
         stage2Result: Stage2Result?,
         localReelURL: URL? = nil,
         savedToPhotos: Bool = false,
         exportedReelAssetId: String? = nil,
         localReelFallbackURL: URL? = nil,
         status: GameStatus = .recording,
         triggerSource: TriggerSource = .manual,
         reelLengthOverride: ReelLength? = nil,
         sceneType: SceneType = .outdoor,
         outputAspectOverride: OutputAspect? = nil,
         rankerTierUsed: RankerTier? = nil,
         captureRecipe: CaptureRecipe? = nil) {
        self.id = id
        self.playerId = playerId
        self.sport = sport
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawVideoURL = rawVideoURL
        self.audioLoudnessURL = audioLoudnessURL
        self.stage1Result = stage1Result
        self.stage2Result = stage2Result
        self.localReelURL = localReelURL
        self.savedToPhotos = savedToPhotos
        self.exportedReelAssetId = exportedReelAssetId
        self.localReelFallbackURL = localReelFallbackURL
        self.status = status
        self.triggerSource = triggerSource
        self.reelLengthOverride = reelLengthOverride
        self.sceneType = sceneType
        self.outputAspectOverride = outputAspectOverride
        self.rankerTierUsed = rankerTierUsed
        self.captureRecipe = captureRecipe
    }

    private enum CodingKeys: String, CodingKey {
        case id, playerId, sport, startedAt, endedAt
        case rawVideoURL, audioLoudnessURL
        case stage1Result, stage2Result
        /// Canonical: relative path under Documents/. Written by encode(to:).
        case localReelRelativePath
        /// Legacy: absolute URL. Read-only — preserved here so games
        /// recorded before the migration can still resolve their reels
        /// after a container UUID change.
        case localReelURL
        case savedToPhotos, exportedReelAssetId
        case localReelFallbackURL
        case status, triggerSource, reelLengthOverride
        case sceneType, outputAspectOverride, rankerTierUsed
        case captureRecipe
    }

    // Custom decode for back-compat across schema migrations:
    //   - exportedReelURL (pre-PHAsset) → ignored; assetId defaults nil
    //   - triggerSource / reelLengthOverride / sceneType defaults if absent
    //   - localReelURL absolute → relativePath migration (see Self.rebase)
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
        // Reel location — prefer the new relative path; if missing, fall
        // back to the legacy absolute URL and rebase it onto the current
        // Documents container so a reinstall doesn't orphan the file.
        if let rel = try c.decodeIfPresent(String.self,
                                           forKey: .localReelRelativePath) {
            localReelURL = Self.absoluteURL(forRelativePath: rel)
        } else if let absolute = try c.decodeIfPresent(URL.self,
                                                       forKey: .localReelURL) {
            localReelURL = Self.rebaseIntoCurrentDocuments(absolute)
        } else {
            localReelURL = nil
        }
        savedToPhotos = try c.decodeIfPresent(Bool.self, forKey: .savedToPhotos) ?? false
        exportedReelAssetId = try c.decodeIfPresent(String.self, forKey: .exportedReelAssetId)
        localReelFallbackURL = try c.decodeIfPresent(URL.self, forKey: .localReelFallbackURL)
        status = try c.decodeIfPresent(GameStatus.self, forKey: .status) ?? .recording
        triggerSource = try c.decodeIfPresent(TriggerSource.self, forKey: .triggerSource) ?? .manual
        reelLengthOverride = try c.decodeIfPresent(ReelLength.self, forKey: .reelLengthOverride)
        sceneType = try c.decodeIfPresent(SceneType.self, forKey: .sceneType) ?? .outdoor
        outputAspectOverride = try c.decodeIfPresent(OutputAspect.self,
                                                     forKey: .outputAspectOverride)
        rankerTierUsed = try c.decodeIfPresent(RankerTier.self,
                                               forKey: .rankerTierUsed)
        captureRecipe = try c.decodeIfPresent(CaptureRecipe.self,
                                              forKey: .captureRecipe)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(playerId, forKey: .playerId)
        try c.encode(sport, forKey: .sport)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(rawVideoURL, forKey: .rawVideoURL)
        try c.encode(audioLoudnessURL, forKey: .audioLoudnessURL)
        try c.encodeIfPresent(stage1Result, forKey: .stage1Result)
        try c.encodeIfPresent(stage2Result, forKey: .stage2Result)
        // Always persist the reel location as a relative path — never an
        // absolute URL. The container UUID iOS hands us changes across
        // reinstalls and some upgrades, so the absolute form goes stale.
        if let url = localReelURL,
           let rel = Self.relativePath(toDocuments: url) {
            try c.encode(rel, forKey: .localReelRelativePath)
        }
        try c.encode(savedToPhotos, forKey: .savedToPhotos)
        try c.encodeIfPresent(exportedReelAssetId, forKey: .exportedReelAssetId)
        try c.encodeIfPresent(localReelFallbackURL, forKey: .localReelFallbackURL)
        try c.encode(status, forKey: .status)
        try c.encode(triggerSource, forKey: .triggerSource)
        try c.encodeIfPresent(reelLengthOverride, forKey: .reelLengthOverride)
        try c.encode(sceneType, forKey: .sceneType)
        try c.encodeIfPresent(outputAspectOverride, forKey: .outputAspectOverride)
        try c.encodeIfPresent(rankerTierUsed, forKey: .rankerTierUsed)
        try c.encodeIfPresent(captureRecipe, forKey: .captureRecipe)
    }

    // MARK: - Relative-path helpers (file-scope so tests can hit them)

    /// Returns the current Documents directory. Resolved fresh every
    /// time so a container UUID change after launch can't poison a
    /// cached value.
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory,
                                 in: .userDomainMask)[0]
    }

    /// Absolute file URL inside the current Documents container for a
    /// relative path like "reels/<id>.mp4".
    static func absoluteURL(forRelativePath rel: String) -> URL {
        documentsURL.appendingPathComponent(rel)
    }

    /// Path of a URL relative to the current Documents container, or
    /// nil if the URL is not inside Documents (and can't be salvaged).
    static func relativePath(toDocuments url: URL) -> String? {
        let docs = documentsURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(docs + "/") {
            return String(p.dropFirst(docs.count + 1))
        }
        // Salvage path: the URL was written against an older container,
        // but the relative structure under Documents/ is stable
        // ("reels/<id>.mp4"). Pull the segment after "/Documents/".
        if let range = p.range(of: "/Documents/", options: [.backwards]) {
            return String(p[range.upperBound...])
        }
        return nil
    }

    /// Rebuild an absolute URL inside the current Documents container
    /// from a (possibly stale) absolute URL written by an older install.
    /// Falls back to assuming the file belongs under Documents/reels/
    /// when no /Documents/ segment is present in the input.
    static func rebaseIntoCurrentDocuments(_ url: URL) -> URL {
        if let rel = relativePath(toDocuments: url) {
            return absoluteURL(forRelativePath: rel)
        }
        return absoluteURL(forRelativePath: "reels/\(url.lastPathComponent)")
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

/// Which ranker tier produced the reel. Tier 1 is the normal path
/// (strong signals); Tier 2 lowers thresholds and uses relative
/// scoring (quiet / solo-practice); Tier 3 is an evenly-sampled
/// montage from the raw video (last-resort, guarantees a reel).
enum RankerTier: Int, Codable {
    case normal = 1
    case weakSignals = 2
    case montageFallback = 3
}

enum PipelineError: Error, LocalizedError {
    case captureFailed(String)
    case stage1Failed(String)
    case stage2Failed(String)
    case compositionFailed(String)
    case noEnrollment
    case insufficientCandidates(found: Int, needed: Int)

    var errorDescription: String? {
        switch self {
        case .captureFailed(let msg):      return "Capture failed: \(msg)"
        case .stage1Failed(let msg):       return "Stage 1 failed: \(msg)"
        case .stage2Failed(let msg):       return "Stage 2 failed: \(msg)"
        case .compositionFailed(let msg):  return "Composition failed: \(msg)"
        case .noEnrollment:                return "No enrolled player."
        case .insufficientCandidates(let f, let n):
            return "Only \(f) candidate moments found (need at least \(n))."
        }
    }
}
