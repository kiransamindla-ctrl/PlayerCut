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
}
