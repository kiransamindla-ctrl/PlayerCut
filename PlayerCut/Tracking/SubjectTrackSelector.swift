//
//  SubjectTrackSelector.swift
//  PlayerCut/Tracking
//
//  Stage 4 subject selection: given the persistent tracks ByteTracker
//  produced over a candidate window, decide WHICH track is "the kid" and
//  hand back that track's per-frame boxes for the follow-subject reframe.
//
//  This is the piece the ByteTracker docstring listed as deferred —
//  "the identified-player picker uses the BEST TRACK across frames, not
//  the best individual detection." Selecting at the track level (not the
//  per-frame-best-detection level the old Stage 2 used) is what stops the
//  reframe crop from flickering between similar-looking players on a
//  multi-player field.
//
//  Selection order:
//    1. IDENTIFIED — the track whose mean identity score (color + face,
//       aggregated by ByteTracker as `identityScore` per detection) is
//       highest AND clears the identity threshold. This is the enrolled
//       player when the identity signals agree.
//    2. FALLBACK (no identity match) — a clearly-dominant central mover:
//       a track that is present for most of the window and stays near
//       frame center, ranked by motion × centrality. Lets the reel follow
//       the action even when we can't positively ID the kid, instead of
//       falling all the way back to Ken Burns. Marked identified == false
//       so the ranker scores it on motion, not a phantom identity.
//    3. None — no track is persistent enough; caller falls back to the
//       ranker's Tier-3 montage (Ken Burns).
//
//  Pure value logic with no Vision/AVFoundation dependency, so it is
//  unit-testable with synthetic detections (the simulator can't run human
//  detection on the synthetic rectangle in SampleVideoFactory).
//

import CoreGraphics
import Foundation

struct SubjectTrackSelector {

    /// Minimum mean per-detection identity score for a track to count as
    /// "the identified player". Mirrors Stage 2's per-frame
    /// identificationThreshold, applied at the track level.
    var identityThreshold: Float = 0.55
    /// A track must have at least this many detections to be considered —
    /// matches the old "≥3 confirmed sightings" gate.
    var minDetections: Int = 3
    /// For the no-identity fallback, the track must be present for at
    /// least this fraction of the analyzed frames (a dominant subject,
    /// not a fleeting background figure).
    var fallbackCoverage: Double = 0.6
    /// For the no-identity fallback, the track's mean centroid must sit
    /// within this radius of frame center (0.5, 0.5) in normalized coords.
    var centralRadius: CGFloat = 0.35

    struct Selection {
        let track: ByteTrack
        /// True when chosen via identity; false when chosen via the
        /// motion-central fallback (low identity confidence).
        let identified: Bool
        /// Mean per-detection identity score over the selected track.
        let meanIdentity: Float
    }

    func select(from tracks: [ByteTrack],
                analyzedFrameCount: Int) -> Selection? {
        let candidates = tracks.filter { $0.detections.count >= minDetections }
        guard !candidates.isEmpty else { return nil }

        // 1. Identified: highest mean identity above threshold.
        let identified = candidates
            .map { ($0, Self.meanIdentity($0)) }
            .filter { $0.1 >= identityThreshold }
            .max { $0.1 < $1.1 }
        if let (track, mean) = identified {
            return Selection(track: track, identified: true, meanIdentity: mean)
        }

        // 2. Fallback: clearly-dominant central mover. Precompute the
        //    motion×centrality score once per track so the comparison
        //    stays trivial to type-check.
        let coverageFloor = Double(analyzedFrameCount) * fallbackCoverage
        let radius = centralRadius
        let scored: [(track: ByteTrack, score: CGFloat)] = candidates
            .filter { Double($0.detections.count) >= coverageFloor }
            .map { track in
                let s = Self.motion(track) * Self.centrality(track, radius: radius)
                return (track, s)
            }
            .filter { $0.score > 0 }
        if let best = scored.max(by: { $0.score < $1.score }) {
            return Selection(track: best.track,
                             identified: false,
                             meanIdentity: Self.meanIdentity(best.track))
        }
        return nil
    }

    // MARK: - Track metrics

    static func meanIdentity(_ t: ByteTrack) -> Float {
        guard !t.detections.isEmpty else { return 0 }
        return t.detections.map(\.identityScore).reduce(0, +)
            / Float(t.detections.count)
    }

    /// Total normalized path length of the track centroid. A static
    /// subject scores ~0; a mover scores higher.
    static func motion(_ t: ByteTrack) -> CGFloat {
        let pts = t.centroidPath.map(\.point)
        guard pts.count > 1 else { return 0 }
        var length: CGFloat = 0
        for i in 1..<pts.count {
            length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        return length
    }

    /// 1.0 at frame center, decaying to 0 at `radius`, clamped to 0
    /// outside. Used so the fallback prefers a centered subject.
    static func centrality(_ t: ByteTrack, radius: CGFloat) -> CGFloat {
        let pts = t.centroidPath.map(\.point)
        guard !pts.isEmpty else { return 0 }
        let mx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let my = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        let dist = hypot(mx - 0.5, my - 0.5)
        guard radius > 0 else { return 0 }
        return max(0, 1 - dist / radius)
    }
}
