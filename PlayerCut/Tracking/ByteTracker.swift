//
//  ByteTracker.swift
//  PlayerCut/Tracking
//
//  Swift port stub of the BYTETrack reference implementation
//  (https://github.com/ifzhang/ByteTrack — MIT). The full IoU + Hungarian
//  assignment with two-stage association lands later; this stub gives
//  Stage 2 a typed surface to plug into so the interface is stable.
//
//  Current behaviour: returns each detection as its own one-frame
//  track. Production swap-in needs the full association logic.
//
//  TODO Tracking-LAUNCH: implement
//   - Track state machine (.tentative / .tracked / .lost / .removed)
//   - IoU cost matrix + Hungarian assignment (linear_assignment)
//   - High-confidence first pass, low-confidence salvage pass
//   - Kalman filter for predicted bbox between observations
//   - Optional ReID embedding feed (jersey color / face print) into
//     identification confidence aggregator
//

import CoreGraphics
import Foundation

/// One observation handed to the tracker per frame.
struct ByteDetection {
    let frameTime: Double
    let box: CGRect            // normalized 0..1
    let confidence: Float      // 0..1
    /// Optional per-detection identity score from upstream stages
    /// (color/face/OCR). The tracker aggregates these per track.
    var identityScore: Float = 0
}

/// A persistent track across frames.
struct ByteTrack: Identifiable {
    let id: Int
    var detections: [ByteDetection]
    var aggregateIdentityScore: Float

    /// Mean centroid path — useful when the composer needs a smoothed
    /// reframing anchor.
    var centroidPath: [(time: Double, point: CGPoint)] {
        detections.map { ($0.frameTime,
                          CGPoint(x: $0.box.midX, y: $0.box.midY)) }
    }
}

final class ByteTracker {
    private var nextID: Int = 0
    private(set) var tracks: [ByteTrack] = []

    func reset() {
        nextID = 0
        tracks.removeAll(keepingCapacity: true)
    }

    /// Feed one frame of detections. Returns the active track list.
    @discardableResult
    func step(detections: [ByteDetection]) -> [ByteTrack] {
        // Stub: each detection becomes its own one-frame track.
        for det in detections {
            nextID += 1
            tracks.append(ByteTrack(id: nextID,
                                    detections: [det],
                                    aggregateIdentityScore: det.identityScore))
        }
        return tracks
    }

    /// The track with the highest aggregate identity score across all
    /// observations. Used by Stage 2 to pick "your kid" from the
    /// candidate tracks within a window.
    func bestIdentifiedTrack(minScore: Float = 0.55) -> ByteTrack? {
        tracks
            .filter { $0.aggregateIdentityScore >= minScore }
            .max(by: { $0.aggregateIdentityScore < $1.aggregateIdentityScore })
    }
}
