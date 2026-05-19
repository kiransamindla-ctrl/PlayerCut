//
//  HighlightRanker.swift
//  PlayerCut
//
//  Selects the final ~10–14 clips from Stage 2 moments, applying diversity
//  constraints so the reel doesn't show the same play twice.
//

import Foundation
import os.log

struct ReelPlan {
    var selected: [SelectedClip]
    var totalDuration: Double
}

struct SelectedClip {
    let moment: ScoredMoment
    var clipStart: Double
    var clipEnd: Double
    var duration: Double { clipEnd - clipStart }
}

struct RankerConfig {
    var targetTotalDuration: Double = 60.0
    var minClipDuration: Double = 4.0
    var maxClipDuration: Double = 6.0
    var hardMaxClipDuration: Double = 8.0   // for exceptional moments
    var minSeparation: Double = 30.0        // seconds between clip centers
    var minClips: Int = 8
    var maxClips: Int = 14
    var exceptionalScoreThreshold: Float = 0.85

    /// Preset tuned per reel length. Longer reels relax diversity
    /// (more clips fit) and lean on slightly longer per-clip durations.
    static func `for`(length: ReelLength) -> RankerConfig {
        var c = RankerConfig()
        c.targetTotalDuration = length.targetSeconds
        switch length {
        case .sixtySeconds:
            c.minClips = 10; c.maxClips = 14
            c.minClipDuration = 4; c.maxClipDuration = 6
            c.minSeparation = 30
        case .twoMinutes:
            c.minClips = 18; c.maxClips = 24
            c.minClipDuration = 5; c.maxClipDuration = 7
            c.minSeparation = 25
        case .threeMinutes:
            c.minClips = 25; c.maxClips = 35
            c.minClipDuration = 6; c.maxClipDuration = 8
            c.minSeparation = 20
        case .fiveMinutes:
            c.minClips = 40; c.maxClips = 55
            c.minClipDuration = 6; c.maxClipDuration = 10
            c.minSeparation = 15
        }
        return c
    }
}

final class HighlightRanker {

    private let log = Logger(subsystem: "com.playercut.app", category: "Ranker")
    private let config: RankerConfig

    init(config: RankerConfig = RankerConfig()) {
        self.config = config
    }

    func selectClips(from moments: [ScoredMoment]) -> ReelPlan {
        guard !moments.isEmpty else {
            return ReelPlan(selected: [], totalDuration: 0)
        }

        // Sort by composite score, descending
        let sorted = moments.sorted { $0.compositeScore > $1.compositeScore }
        var selected: [SelectedClip] = []
        var totalDuration: Double = 0

        for moment in sorted {
            if selected.count >= config.maxClips { break }
            if totalDuration >= config.targetTotalDuration { break }

            let center = (moment.window.startTime + moment.window.endTime) / 2

            // Diversity: skip if too close to an already-selected clip
            let tooClose = selected.contains { picked in
                let pickedCenter = (picked.clipStart + picked.clipEnd) / 2
                return abs(pickedCenter - center) < config.minSeparation
            }
            if tooClose { continue }

            // Trim to target clip length, anchored on the highest-activity sub-window
            let targetLength = clipLength(for: moment)
            let halfLength = targetLength / 2

            // Try to center on the densest cluster of player bounding boxes
            let anchor = densestAnchor(in: moment) ?? center

            var clipStart = max(0, anchor - halfLength)
            var clipEnd = clipStart + targetLength

            // Clamp inside the original window bounds (with a small buffer)
            if clipStart < moment.window.startTime - 1 {
                clipStart = max(0, moment.window.startTime - 1)
                clipEnd = clipStart + targetLength
            }
            if clipEnd > moment.window.endTime + 1 {
                clipEnd = moment.window.endTime + 1
                clipStart = max(0, clipEnd - targetLength)
            }

            selected.append(SelectedClip(moment: moment,
                                         clipStart: clipStart,
                                         clipEnd: clipEnd))
            totalDuration += (clipEnd - clipStart)
        }

        // Ensure we have at least the minimum clip count even if it overruns target
        while selected.count < config.minClips {
            // Look for next-best moment we haven't picked, ignoring separation
            let alreadyPicked = Set(selected.map { $0.moment.id })
            guard let next = sorted.first(where: { !alreadyPicked.contains($0.id) }) else {
                break
            }
            let length = config.minClipDuration
            let center = (next.window.startTime + next.window.endTime) / 2
            let start = max(0, center - length / 2)
            selected.append(SelectedClip(moment: next,
                                         clipStart: start,
                                         clipEnd: start + length))
            totalDuration += length
        }

        // Sort selected by chronological order for the final reel
        selected.sort { $0.clipStart < $1.clipStart }

        log.info("Ranker selected \(selected.count) clips totaling \(totalDuration)s")
        return ReelPlan(selected: selected, totalDuration: totalDuration)
    }

    // MARK: - Helpers

    private func clipLength(for moment: ScoredMoment) -> Double {
        if moment.compositeScore >= config.exceptionalScoreThreshold {
            return config.hardMaxClipDuration
        }
        // Linear interpolation between min and max based on composite score
        let normalized = Double(moment.compositeScore)
        let span = config.maxClipDuration - config.minClipDuration
        return config.minClipDuration + span * normalized
    }

    /// Finds the time within the window where the player's bounding box centers
    /// are densest — usually the action peak.
    private func densestAnchor(in moment: ScoredMoment) -> Double? {
        guard !moment.playerBoundingBoxes.isEmpty else { return nil }
        // Bin times into 0.5s buckets, pick the bucket with the most samples
        var buckets: [Int: Int] = [:]
        for box in moment.playerBoundingBoxes {
            let bucket = Int(box.time * 2)
            buckets[bucket, default: 0] += 1
        }
        guard let best = buckets.max(by: { $0.value < $1.value }) else { return nil }
        return Double(best.key) / 2.0
    }
}
