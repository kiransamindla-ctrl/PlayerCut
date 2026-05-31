//
//  SceneClassifier.swift
//  PlayerCut/Vision
//
//  Apple-native scene classification (VNClassifyImageRequest, iOS 13+).
//  Replaces the hardcoded `SceneType = .outdoor` in CaptureView/CoreModels.
//
//  Strategy: sample 3-5 frames from the source video, run the request on
//  each, majority-vote the result into a SceneType. Drives the
//  scene-appropriate LUT default downstream.
//

import AVFoundation
import CoreImage
import Foundation
import Vision
import os.log

enum SceneClassifier {

    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "Scene")

    private static let stadiumKeywords: Set<String> = [
        "stadium", "arena", "field", "court", "soccer_field",
        "basketball_court", "baseball_field", "football_field",
        "track_field", "ice_skating_rink", "tennis_court", "ski_slope"
    ]
    private static let indoorKeywords: Set<String> = [
        "indoor", "gym", "gymnasium", "arena_indoor", "court_indoor",
        "ice_skating_rink_indoor", "swimming_pool_indoor"
    ]
    /// PR #11 S1 — labels Vision's image-classification taxonomy uses for
    /// sports / action scenes. Any of these in the top-3 (confidence
    /// > 0.3) on a candidate window's sampled frame counts toward the
    /// "this is real action" signal and boosts that window's motion
    /// score. Keywords are matched as substrings so plurals + compound
    /// labels ("ball_game", "sports_field") both hit.
    static let actionKeywords: Set<String> = [
        "sports", "sports_equipment", "sports_field",
        "stadium", "court", "athlete", "ball_game",
        "soccer", "basketball", "football", "hockey",
        "baseball", "tennis", "track", "crowd",
        "play", "playing", "game", "match"
    ]
    /// Boost range per spec: 1.2× when one action label hits the top-3,
    /// 1.5× when two or more do. Capped at 1.5× so a single hot window
    /// can't dominate the ranker.
    static let actionBoostMin: Float = 1.2
    static let actionBoostMax: Float = 1.5
    /// Apple's VNClassifyImageRequest returns ~1300 labels per frame;
    /// we only consider the top-3 with confidence > 0.3 — the cutoff
    /// where labels go from "this is what I see" to "I'm guessing."
    static let topNLabels = 3
    static let labelConfidenceFloor: Float = 0.30

    /// Classify the dominant scene in a source video by sampling
    /// `sampleCount` evenly-spaced frames and majority-voting Vision's
    /// top labels.
    static func classify(videoURL: URL,
                         sampleCount: Int = 4) async -> SceneType {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration) else {
            log.warning("Scene: duration load failed; defaulting to .outdoor")
            return .outdoor
        }
        let total = duration.seconds
        guard total > 0 else { return .outdoor }

        var indoorVotes = 0
        var outdoorVotes = 0
        var stadiumVotes = 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        for i in 0..<sampleCount {
            let t = total * (Double(i) + 0.5) / Double(sampleCount)
            guard let cg = try? gen.copyCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600),
                actualTime: nil) else { continue }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.warning("Scene classify failed at t=\(t, format: .fixed(precision: 1))s: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let observations = request.results else { continue }
            // Take top 5 labels above 0.05 confidence.
            let top = observations
                .filter { $0.confidence > 0.05 }
                .prefix(5)
                .map { $0.identifier.lowercased() }
            for label in top {
                if stadiumKeywords.contains(label) { stadiumVotes += 1 }
                if indoorKeywords.contains(label) { indoorVotes += 1 }
                if label.hasSuffix("_outdoor") || label.contains("field")
                    || label == "outdoor" { outdoorVotes += 1 }
            }
        }
        log.info("Scene votes — indoor=\(indoorVotes) outdoor=\(outdoorVotes) stadium=\(stadiumVotes)")
        // Stadium is a flavour of outdoor; indoor wins only when it has
        // strictly more votes than indoor+outdoor combined to avoid
        // misfiring on shaded outdoor frames.
        if indoorVotes > (outdoorVotes + stadiumVotes) {
            return .indoor
        }
        return .outdoor
    }

    // MARK: - PR #11 S1 — per-window action boost

    /// Pure helper. Inspects the top-N VNClassifyImage labels for a
    /// single sampled frame and returns the boost factor to apply to
    /// the host candidate window's motion score.
    /// One action keyword above the confidence floor → 1.2×.
    /// Two or more → 1.5×.
    /// None → 1.0 (unchanged).
    static func actionBoost(forLabels labels: [(identifier: String, confidence: Float)])
        -> Float {
        let hits = labels.prefix(topNLabels)
            .filter { $0.confidence > labelConfidenceFloor }
            .filter { obs in
                let id = obs.identifier.lowercased()
                return actionKeywords.contains(where: { id.contains($0) })
            }
            .count
        switch hits {
        case 0:  return 1.0
        case 1:  return actionBoostMin
        default: return actionBoostMax
        }
    }

    /// Samples one frame per candidate window via AVAssetImageGenerator at
    /// `analysisLongEdge` (default 480) and returns the boost factor map.
    /// Cost ≈ 1 frame decode + 1 VNClassifyImageRequest per window — a
    /// few ms each on A15+. Stride is per-spec (frame stride 12 ≈ once
    /// every 12 source frames at 30 fps), implemented by sampling the
    /// window's midpoint rather than walking the whole window.
    static func actionBoostScores(
        videoURL: URL,
        windows: [CandidateWindow],
        analysisLongEdge: Int = 480
    ) async -> [UUID: Float] {
        guard !windows.isEmpty else { return [:] }
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: analysisLongEdge,
                                 height: analysisLongEdge)
        gen.requestedTimeToleranceBefore = CMTime(
            seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(
            seconds: 0.25, preferredTimescale: 600)

        var out: [UUID: Float] = [:]
        for window in windows {
            let mid = (window.startTime + window.endTime) / 2
            guard let cg = try? gen.copyCGImage(
                at: CMTime(seconds: mid, preferredTimescale: 600),
                actualTime: nil) else {
                out[window.id] = 1.0
                continue
            }
            let req = VNClassifyImageRequest()
            do {
                try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            } catch {
                log.warning("ActionBoost classify failed @ t=\(mid, format: .fixed(precision: 2))s: \(error.localizedDescription, privacy: .public)")
                out[window.id] = 1.0
                continue
            }
            let labels = (req.results ?? []).map {
                (identifier: $0.identifier, confidence: $0.confidence)
            }
            out[window.id] = actionBoost(forLabels: labels)
        }
        return out
    }
}
