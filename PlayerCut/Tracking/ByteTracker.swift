//
//  ByteTracker.swift
//  PlayerCut/Tracking
//
//  Swift implementation of a motion-centric multi-object tracker for
//  sports footage. Modeled on the BYTETrack design
//  (// SOURCE: github.com/ifzhang/ByteTrack, MIT) but simplified for
//  v1: greedy IoU association (not Hungarian), constant-velocity
//  motion prediction (not Kalman), single-pass association on the
//  full detection set per frame (BYTETrack's two-stage high/low-conf
//  split is documented as a follow-up).
//
//  What this delivers vs. the previous per-frame stub:
//    - Persistent track IDs across frames within a candidate window
//    - Constant-velocity motion prediction for short occlusion gaps
//    - Track lifecycle: .tentative → .tracked → .lost → .removed
//    - Identity-score aggregation per track (the identified-player
//      picker uses the BEST TRACK across frames, not the best
//      individual detection)
//
//  Deferred (called out in the Section 4 commit message):
//    - Full Kalman filter (covariance-weighted prediction)
//    - Hungarian assignment for the cost matrix
//    - BYTETrack's two-stage high-conf / low-conf cascade
//    - VNTrackObjectRequest pairing for cross-frame ReID
//    - Stage 2 rewire to actually consume tracks
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

    // MARK: - Tunables

    /// Detections with IoU below this floor are never matched to an
    /// existing track. Empirically ~0.3 is the sports-footage sweet
    /// spot — looser invites swaps, tighter loses fast-moving subjects.
    private let iouThreshold: CGFloat = 0.3
    /// Number of consecutive missed frames before a `.tracked` track
    /// is downgraded to `.lost`.
    private let lostFrameBudget: Int = 6
    /// Frames a `.lost` track persists (used for short-term gap-fill)
    /// before it's `.removed`.
    private let removalFrameBudget: Int = 30

    // MARK: - State

    private enum Status {
        case tentative, tracked, lost, removed
    }

    private struct ActiveTrack {
        let id: Int
        var status: Status
        var detections: [ByteDetection]
        var aggregateIdentity: Float
        /// Constant-velocity prediction state.
        var lastBox: CGRect
        var velocity: CGSize
        var lastSeenTime: Double
        var consecutiveMisses: Int
    }

    private var nextID: Int = 0
    private var active: [ActiveTrack] = []

    /// Read-only snapshot of all tracks (any status) seen since reset.
    /// Stage 2 / EditPlanBuilder consumes this at window-end.
    var tracks: [ByteTrack] {
        active.map { t in
            ByteTrack(id: t.id,
                      detections: t.detections,
                      aggregateIdentityScore: t.aggregateIdentity)
        }
    }

    // MARK: - Public surface

    func reset() {
        nextID = 0
        active.removeAll(keepingCapacity: true)
    }

    /// Feed one frame of detections. Returns the current active track
    /// list (excluding removed). Caller drives time forward by passing
    /// detections from monotonically-increasing frameTimes.
    @discardableResult
    func step(detections: [ByteDetection]) -> [ByteTrack] {
        let now = detections.first?.frameTime ?? lastSeenTimeMax()

        // 1. Predict every active track's expected box at `now`.
        for i in active.indices where active[i].status != .removed {
            let dt = now - active[i].lastSeenTime
            if dt > 0 {
                let predicted = CGRect(
                    x: active[i].lastBox.origin.x + active[i].velocity.width * dt,
                    y: active[i].lastBox.origin.y + active[i].velocity.height * dt,
                    width: active[i].lastBox.width,
                    height: active[i].lastBox.height)
                // Clamp to [0,1] bounds — we don't predict off-screen.
                active[i].lastBox = clampBox(predicted)
            }
        }

        // 2. Build IoU cost matrix between active non-removed tracks
        //    and incoming detections; greedy-assign by highest IoU
        //    above threshold.
        let candidateIndices = active.enumerated()
            .compactMap { (idx, t) in t.status == .removed ? nil : idx }
        var unmatchedDets = Array(detections.indices)
        var assignments: [(trackIdx: Int, detIdx: Int)] = []

        // Sort pairs by IoU descending; pick greedy.
        var pairs: [(trackIdx: Int, detIdx: Int, iou: CGFloat)] = []
        for ti in candidateIndices {
            for di in unmatchedDets {
                let iou = Self.iou(active[ti].lastBox,
                                   detections[di].box)
                if iou >= iouThreshold {
                    pairs.append((ti, di, iou))
                }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var usedTracks = Set<Int>()
        var usedDets = Set<Int>()
        for p in pairs {
            if usedTracks.contains(p.trackIdx) { continue }
            if usedDets.contains(p.detIdx) { continue }
            assignments.append((p.trackIdx, p.detIdx))
            usedTracks.insert(p.trackIdx)
            usedDets.insert(p.detIdx)
        }
        unmatchedDets.removeAll(where: usedDets.contains)

        // 3. Update matched tracks.
        for (ti, di) in assignments {
            let det = detections[di]
            let prevBox = active[ti].lastBox
            let dt = max(0.001, det.frameTime - active[ti].lastSeenTime)
            active[ti].velocity = CGSize(
                width: (det.box.origin.x - prevBox.origin.x) / dt,
                height: (det.box.origin.y - prevBox.origin.y) / dt)
            active[ti].lastBox = det.box
            active[ti].detections.append(det)
            active[ti].aggregateIdentity += det.identityScore
            active[ti].lastSeenTime = det.frameTime
            active[ti].consecutiveMisses = 0
            // Tentative → tracked once a track has ≥3 detections.
            if active[ti].status == .tentative,
               active[ti].detections.count >= 3 {
                active[ti].status = .tracked
            } else if active[ti].status == .lost {
                // Re-acquired after being lost — promote back to tracked.
                active[ti].status = .tracked
            }
        }

        // 4. Spawn new tentative tracks for unmatched detections.
        for di in unmatchedDets {
            let det = detections[di]
            nextID += 1
            active.append(ActiveTrack(
                id: nextID,
                status: .tentative,
                detections: [det],
                aggregateIdentity: det.identityScore,
                lastBox: det.box,
                velocity: .zero,
                lastSeenTime: det.frameTime,
                consecutiveMisses: 0))
        }

        // 5. Advance miss counter on unmatched non-removed tracks +
        //    promote .tracked → .lost, .lost → .removed.
        for ti in candidateIndices where !usedTracks.contains(ti) {
            active[ti].consecutiveMisses += 1
            switch active[ti].status {
            case .tracked:
                if active[ti].consecutiveMisses > lostFrameBudget {
                    active[ti].status = .lost
                }
            case .lost:
                if active[ti].consecutiveMisses > removalFrameBudget {
                    active[ti].status = .removed
                }
            case .tentative:
                // Tentatives that don't grow legs in 2 frames die quick.
                if active[ti].consecutiveMisses > 2 {
                    active[ti].status = .removed
                }
            case .removed:
                break
            }
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

    // MARK: - Math

    /// Intersection-over-union for two normalized boxes.
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }

    private func clampBox(_ r: CGRect) -> CGRect {
        let x = min(max(0, r.origin.x), max(0, 1 - r.width))
        let y = min(max(0, r.origin.y), max(0, 1 - r.height))
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    private func lastSeenTimeMax() -> Double {
        active.map(\.lastSeenTime).max() ?? 0
    }
}
