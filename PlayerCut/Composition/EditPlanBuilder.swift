//
//  EditPlanBuilder.swift
//  PlayerCut/Composition
//
//  Converts the ranker's ReelPlan + player + music context into a fully
//  rendered EditPlan. Every cinematic decision lives here:
//   - cold open from the highest-energy moment in the source plan
//   - title + closing card metadata derived from the player + game
//   - beat grid derived from the music track BPM (or sensible defaults)
//   - per-clip crop keyframes (critically-damped smoothing on the
//     tracked player bounding boxes, scaled to keep them at ~45% of
//     output height)
//   - per-clip speed curve (slow-mo ramp around the action apex when
//     style allows + the clip's energy exceeds a threshold)
//   - per-boundary transition (energy-driven; opening always fades
//     from black)
//
//  All sampling rates and thresholds are tunable here so future style
//  presets can override them without touching the renderer.
//

import CoreGraphics
import Foundation
import os.log

struct EditPlanBuilder {

    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "EditPlan")

    /// Knobs that can be lowered for weaker devices to keep render
    /// time tractable. The orchestrator picks a profile based on
    /// device class + thermal state before calling build().
    struct PerfProfile {
        /// How often to emit auto-reframe crop keyframes within a
        /// clip. Higher = smoother but more layer instructions in
        /// the video composition.
        var cropKeyframeHz: Double = 10
        /// Critical-damping omega — higher follows the player faster
        /// (and more jitter); lower is smoother but lags.
        var dampingOmega: Double = 4.5
        /// Max output translation velocity in normalized units/sec.
        /// Clamps "human-operator" pan speed.
        var maxPanVelocity: Double = 0.6
        /// Threshold above which a clip earns a speed ramp.
        var speedRampEnergyThreshold: Float = 0.55
        /// Speed-ramp deepest factor (slowest at apex).
        var apexSpeedFactor: Double = 0.4
        /// Whether to enable expensive transitions (zoomPunch /
        /// lightLeakWipe). When false, the style falls back to
        /// dissolves + hard cuts only.
        var allowsHeavyTransitions: Bool = true

        static let highEnd = PerfProfile()
        static let midRange = PerfProfile(cropKeyframeHz: 6,
                                          dampingOmega: 4,
                                          maxPanVelocity: 0.5,
                                          speedRampEnergyThreshold: 0.6,
                                          apexSpeedFactor: 0.5,
                                          allowsHeavyTransitions: true)
        static let conservative = PerfProfile(cropKeyframeHz: 4,
                                              dampingOmega: 3.5,
                                              maxPanVelocity: 0.4,
                                              speedRampEnergyThreshold: 0.7,
                                              apexSpeedFactor: 0.6,
                                              allowsHeavyTransitions: false)
    }

    let profile: PerfProfile
    let style: EditStyle
    let output: OutputSpec

    /// Source video duration (used to clamp cold-open / clip windows).
    let sourceDuration: Double

    init(style: EditStyle,
         output: OutputSpec,
         sourceDuration: Double,
         profile: PerfProfile = .highEnd) {
        self.style = style
        self.output = output
        self.sourceDuration = sourceDuration
        self.profile = profile
    }

    func build(from plan: ReelPlan,
               player: PlayerEnrollment,
               game: GameSession,
               musicURL: URL?,
               musicBPM: Double?) -> EditPlan {

        // Cold open: the single highest-energy moment.
        let coldOpenClip = makeColdOpen(plan: plan)

        // Body clips: remove the cold-open source moment to avoid a
        // dupe, then build a ClipPlan per remaining moment.
        var bodyMoments = plan.selected
        if let cold = coldOpenClip,
           let idx = bodyMoments.firstIndex(where: { $0.moment.id == cold.id }) {
            bodyMoments.remove(at: idx)
        }
        let body = bodyMoments.enumerated().map { (i, sel) in
            buildBodyClip(from: sel,
                          isLast: i == bodyMoments.count - 1)
        }

        // Beat grid: derive from BPM if available, else use a per-style
        // default that approximates a musical pulse. The grid spans
        // beyond totalDuration so the renderer never indexes out.
        let bpm = musicBPM ?? defaultBPM(for: style)
        let beatGrid = makeBeatGrid(bpm: bpm,
                                    spanSeconds: 60 * 6) // 6 min ceiling

        let titleCard = makeTitleCard(player: player, game: game)
        let lowerThird = LowerThirdSpec(
            primaryText: player.name.uppercased(),
            secondaryText: "#\(player.jerseyNumber)")
        let closing = ClosingCardSpec(
            primaryText: "PlayerCut",
            secondaryText: game.startedAt.formatted(date: .abbreviated,
                                                    time: .omitted))

        return EditPlan(coldOpen: coldOpenClip.map {
                            asColdOpenClip($0, energy: $0.energy)
                        },
                        titleCard: titleCard,
                        lowerThird: lowerThird,
                        body: body,
                        closingCard: closing,
                        beatGrid: beatGrid,
                        style: style,
                        output: output,
                        musicURL: musicURL,
                        sourceTier: plan.tier)
    }

    // MARK: - Cold open

    /// Convert the highest-energy SelectedClip into a 1.2..1.8s ColdOpen
    /// ClipPlan centered on the densest-action anchor.
    private func makeColdOpen(plan: ReelPlan) -> ScoredColdOpenChoice? {
        guard let best = plan.selected.max(by: { energy(of: $0) < energy(of: $1) }) else {
            return nil
        }
        let bestEnergy = energy(of: best)
        // If the best moment isn't actually energetic (e.g. Tier 3
        // montage), skip the cold open and let the first body clip lead.
        guard bestEnergy >= 0.45 else { return nil }

        // 1.6s target, clamped to the clip's source range.
        let target: Double = 1.6
        let anchor = anchorTime(in: best.moment) ?? best.center
        let halfLen = target / 2
        var start = max(0, anchor - halfLen)
        var end = min(sourceDuration, start + target)
        if end - start < 1.2 {
            // Either clamped at source start or end — slide back.
            start = max(0, end - 1.2)
        }

        let crop = buildCropKeyframes(boxes: best.moment.playerBoundingBoxes,
                                      sourceStart: start,
                                      sourceEnd: end,
                                      tighter: true)

        // Cold open is always slow-mo to milk the apex.
        let speed: SpeedCurve = style.allowsSpeedRamps
            ? rampedSpeedCurve(apexFraction: 0.6,
                               deepestFactor: profile.apexSpeedFactor)
            : SpeedCurve.realTime

        let id = UUID()
        let plan = ClipPlan(id: id,
                            sourceStart: start,
                            sourceEnd: end,
                            cropKeyframes: crop,
                            speedCurve: speed,
                            outgoingTransition: .fadeFromBlack, // ignored
                            energy: Float(bestEnergy))
        return ScoredColdOpenChoice(plan: plan,
                                    id: best.moment.id,
                                    energy: Float(bestEnergy))
    }

    private struct ScoredColdOpenChoice {
        let plan: ClipPlan
        let id: UUID
        let energy: Float
    }

    private func asColdOpenClip(_ c: ScoredColdOpenChoice,
                                energy: Float) -> ClipPlan {
        var p = c.plan
        p.energy = energy
        return p
    }

    // MARK: - Body clips

    private func buildBodyClip(from sel: SelectedClip,
                               isLast: Bool) -> ClipPlan {
        let e = energy(of: sel)
        let crop = buildCropKeyframes(boxes: sel.moment.playerBoundingBoxes,
                                      sourceStart: sel.clipStart,
                                      sourceEnd: sel.clipEnd,
                                      tighter: false)

        let allowsRamp = style.allowsSpeedRamps
            && Float(e) >= profile.speedRampEnergyThreshold
        let speed: SpeedCurve = allowsRamp
            ? rampedSpeedCurve(apexFraction: anchorFraction(in: sel),
                               deepestFactor: profile.apexSpeedFactor)
            : SpeedCurve.realTime

        let transition: TransitionKind = isLast
            ? .crossDissolve
            : pickTransition(for: Float(e))

        return ClipPlan(id: sel.moment.id,
                        sourceStart: sel.clipStart,
                        sourceEnd: sel.clipEnd,
                        cropKeyframes: crop,
                        speedCurve: speed,
                        outgoingTransition: transition,
                        energy: Float(e))
    }

    // MARK: - Auto-reframe (Part 3A)

    /// Critically-damped tracking of the player center, scaled so the
    /// player sits at ~45% of the output viewport height. Falls back to
    /// the source-frame center when no boxes are available.
    private func buildCropKeyframes(boxes: [TimedBox],
                                    sourceStart: Double,
                                    sourceEnd: Double,
                                    tighter: Bool) -> [CropKeyframe] {
        let duration = sourceEnd - sourceStart
        guard duration > 0 else { return [] }
        let hz = profile.cropKeyframeHz
        let n = max(2, Int(ceil(duration * hz)))

        // Anchor samples in clip-local time. For windows with no boxes
        // we still emit a single keyframe at center.
        let local = boxes.filter {
            $0.time >= sourceStart - 0.25 && $0.time <= sourceEnd + 0.25
        }

        if local.isEmpty {
            return [
                CropKeyframe(time: 0,
                             center: CGPoint(x: 0.5, y: 0.5),
                             scale: tighter ? 1.08 : 1.0),
                CropKeyframe(time: duration,
                             center: CGPoint(x: 0.5, y: 0.5),
                             scale: tighter ? 1.08 : 1.0)
            ]
        }

        // Convert to (time-from-clip-start, center, scale).
        let raw: [(Double, CGPoint, CGFloat)] = local.map { box in
            let t = box.time - sourceStart
            let c = CGPoint(x: box.box.midX, y: box.box.midY)
            // Scale → keep the player at ~45% of output height. The
            // crop window height is targetH; player-box height in
            // normalized source coords is box.height. We want
            // box.height * scale ≈ 0.45 (in output's normalized space)
            // when accounting for the source/output aspect mismatch.
            // For 9:16 from a 16:9 source the crop width is narrower
            // than source width by factor 9/16. We approximate by
            // clamping scale to a sensible band.
            let h = max(0.06, Double(box.box.height))
            let desired = 0.45 / h
            let s = CGFloat(min(1.45, max(1.0, desired * (tighter ? 1.1 : 1.0))))
            return (t, c, s)
        }

        // Critical damping over a uniform time grid. omega controls
        // tracking responsiveness; the second-order critically-damped
        // step is x'' + 2ω·x' + ω²·(x - target) = 0.
        var keyframes: [CropKeyframe] = []
        let omega = profile.dampingOmega
        let dt = duration / Double(n - 1)
        var cx: CGFloat = raw[0].1.x
        var cy: CGFloat = raw[0].1.y
        var cs: CGFloat = raw[0].2
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var vs: CGFloat = 0

        for i in 0..<n {
            let t = Double(i) * dt
            let target = interpolateTarget(raw: raw, atTime: t)
            // Critical damping step (semi-implicit Euler).
            let ax = -2 * omega * Double(vx) - omega * omega * Double(cx - target.center.x)
            let ay = -2 * omega * Double(vy) - omega * omega * Double(cy - target.center.y)
            let as_ = -2 * omega * Double(vs) - omega * omega * Double(cs - target.scale)
            vx += CGFloat(ax * dt)
            vy += CGFloat(ay * dt)
            vs += CGFloat(as_ * dt)
            // Velocity clamp (human-operator pan speed).
            let maxV = CGFloat(profile.maxPanVelocity)
            vx = clamp(vx, lo: -maxV, hi: maxV)
            vy = clamp(vy, lo: -maxV, hi: maxV)
            cx += vx * CGFloat(dt)
            cy += vy * CGFloat(dt)
            cs += vs * CGFloat(dt)
            // Clamp center within source bounds; the renderer will
            // further clamp the crop window itself.
            cx = clamp(cx, lo: 0, hi: 1)
            cy = clamp(cy, lo: 0, hi: 1)
            cs = clamp(cs, lo: 1.0, hi: 1.45)
            keyframes.append(CropKeyframe(time: t,
                                          center: CGPoint(x: cx, y: cy),
                                          scale: cs))
        }
        return keyframes
    }

    private func interpolateTarget(raw: [(Double, CGPoint, CGFloat)],
                                   atTime t: Double)
        -> (center: CGPoint, scale: CGFloat) {
        // Find bracketing samples; linearly interpolate.
        if t <= raw[0].0 { return (raw[0].1, raw[0].2) }
        if t >= raw.last!.0 { return (raw.last!.1, raw.last!.2) }
        for i in 0..<(raw.count - 1) {
            let a = raw[i]
            let b = raw[i + 1]
            if t >= a.0 && t <= b.0 {
                let span = max(1e-6, b.0 - a.0)
                let f = CGFloat((t - a.0) / span)
                let c = CGPoint(x: a.1.x + (b.1.x - a.1.x) * f,
                                y: a.1.y + (b.1.y - a.1.y) * f)
                let s = a.2 + (b.2 - a.2) * f
                return (c, s)
            }
        }
        return (raw.last!.1, raw.last!.2)
    }

    private func clamp<T: Comparable>(_ v: T, lo: T, hi: T) -> T {
        min(max(v, lo), hi)
    }

    // MARK: - Speed curves (Part 3B)

    /// Three-segment ramp: real-time → slow-mo at apex → real-time.
    /// `apexFraction` is the source-fraction (0..1) where the deepest
    /// slow-mo lands.
    private func rampedSpeedCurve(apexFraction f: Double,
                                  deepestFactor: Double) -> SpeedCurve {
        // Anchors: clamp so each segment is at least 10% of the source.
        let a = clamp(f - 0.18, lo: 0.05, hi: 0.7)
        let b = clamp(f + 0.18, lo: 0.3, hi: 0.95)
        // Eased "into" and "out of" slow-mo via an intermediate factor.
        let mid = (deepestFactor + 1.0) / 2.0
        return SpeedCurve(segments: [
            .init(sourceFractionStart: 0,   sourceFractionEnd: a,   factor: 1.0),
            .init(sourceFractionStart: a,   sourceFractionEnd: (a + f) / 2, factor: mid),
            .init(sourceFractionStart: (a + f) / 2, sourceFractionEnd: (f + b) / 2,
                  factor: deepestFactor),
            .init(sourceFractionStart: (f + b) / 2, sourceFractionEnd: b, factor: mid),
            .init(sourceFractionStart: b,   sourceFractionEnd: 1,   factor: 1.0),
        ])
    }

    /// Find the densest-action moment within a SelectedClip, expressed
    /// as a fraction (0..1) of the clip's source duration.
    private func anchorFraction(in sel: SelectedClip) -> Double {
        guard let a = anchorTime(in: sel.moment) else { return 0.5 }
        let span = max(0.01, sel.clipEnd - sel.clipStart)
        return clamp((a - sel.clipStart) / span, lo: 0.1, hi: 0.9)
    }

    private func anchorTime(in moment: ScoredMoment) -> Double? {
        guard !moment.playerBoundingBoxes.isEmpty else { return nil }
        // Center of mass over the bounding-box samples — represents
        // where the action density peaks.
        let times = moment.playerBoundingBoxes.map { $0.time }
        return times.reduce(0, +) / Double(times.count)
    }

    // MARK: - Transitions (Part 3D)

    private func pickTransition(for energy: Float) -> TransitionKind {
        if !profile.allowsHeavyTransitions {
            return energy >= 0.65 ? .crossDissolve : .crossDissolve
        }
        switch style {
        case .energetic:
            if energy >= 0.7 { return .zoomPunch }
            if energy >= 0.5 { return .whipPan }
            return .crossDissolve
        case .playful:
            if energy >= 0.65 { return .lightLeakWipe }
            return .crossDissolve
        case .cinematic, .chill:
            return .crossDissolve
        }
    }

    // MARK: - Beat grid (Part 3C)

    private func defaultBPM(for style: EditStyle) -> Double {
        switch style {
        case .energetic: return 140
        case .cinematic: return 90
        case .playful:   return 120
        case .chill:     return 88
        }
    }

    private func makeBeatGrid(bpm: Double, spanSeconds: Double) -> [Double] {
        let interval = 60.0 / max(40.0, bpm)
        let n = max(8, Int(ceil(spanSeconds / interval)))
        return (0...n).map { Double($0) * interval }
    }

    // MARK: - Title card (Part 3G)

    private func makeTitleCard(player: PlayerEnrollment,
                               game: GameSession) -> TitleCardSpec {
        let date = game.startedAt.formatted(date: .abbreviated, time: .omitted)
        return TitleCardSpec(
            primaryText: player.name.uppercased(),
            secondaryText: "#\(player.jerseyNumber) · \(date.uppercased())",
            accentHex: defaultAccentHex(for: player.musicVibe))
    }

    /// We don't have an authoritative jersey color string yet (the
    /// HSV histogram doesn't survive a clean round-trip to "the user's
    /// jersey is orange"). Use a per-vibe accent until enrollment
    /// captures the jersey RGB directly.
    private func defaultAccentHex(for vibe: MusicVibe) -> String {
        switch vibe {
        case .energetic: return "#FF6A1F"
        case .cinematic: return "#3A8DFF"
        case .playful:   return "#FFC93C"
        case .chill:     return "#7CD2A6"
        }
    }

    // MARK: - Energy

    /// Energy score for a SelectedClip, 0..1. Combines composite + audio
    /// + action with mild emphasis on the action term for transition
    /// selection.
    private func energy(of sel: SelectedClip) -> Double {
        let comp = Double(sel.moment.compositeScore)
        let audio = Double(sel.moment.window.audioScore)
        let act = Double(sel.moment.activityScore)
        let raw = 0.45 * comp + 0.30 * act + 0.25 * audio
        return min(1.0, max(0.0, raw))
    }
}

// MARK: - SelectedClip convenience

private extension SelectedClip {
    var center: Double { (clipStart + clipEnd) / 2 }
}
