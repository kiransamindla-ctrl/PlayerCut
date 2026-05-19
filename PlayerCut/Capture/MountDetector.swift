//
//  MountDetector.swift
//  PlayerCut/Capture
//
//  Watches Core Motion to decide whether the phone is on a tripod in
//  landscape, motionless, and ready to record. The capture UI consumes
//  the published state to auto-start a session without requiring a tap.
//
//  Heuristics — tuned for "hand puts phone on tripod, walks 5 ft away":
//   - Landscape orientation: the phone's long axis is roughly horizontal,
//     so gravity points mostly along ±x. We check the simpler condition
//     |gravity.y| < 0.3 AND |gravity.z| < 0.3 (which implies |gravity.x|
//     is close to 1 since gravity is unit-length).
//   - Angular stillness: instantaneous |ω| < 0.05 rad/s.
//   - Translational stillness: variance of userAcceleration over a 2-second
//     rolling window < 0.005 g² (filters hand tremor).
//   - All three must hold continuously for 10 seconds to promote to
//     .mounted; any disqualifying frame resets the clock.
//

import CoreMotion
import Foundation
import os.log

@MainActor
final class MountDetector {

    enum State: String, Equatable {
        case unknown        // not started, or motion unavailable
        case moving         // hand-held / actively being repositioned
        case stable         // landscape + still, but not yet for 10 s
        case mounted        // sustained stable → safe to auto-start
    }

    /// Subscribe with `for await s in detector.states { … }`. Single-
    /// consumer stream; the detector buffers the most recent change so a
    /// late subscriber catches up without missing the latest transition.
    let states: AsyncStream<State>
    private(set) var state: State = .unknown

    let stabilityWindow: TimeInterval = 10.0
    let varianceWindow: TimeInterval = 2.0

    private let motionManager = CMMotionManager()
    private let log = Logger(subsystem: "com.playercut.app", category: "Mount")
    private let sampleHz: Double = 20
    private var continuation: AsyncStream<State>.Continuation?

    // Rolling window of userAcceleration components for variance.
    private var accelSamples: [(x: Double, y: Double, z: Double)] = []

    // First time we entered a qualifying state in the current quiet
    // streak. Reset to nil whenever any condition fails.
    private var stableSince: Date?

    init() {
        var c: AsyncStream<State>.Continuation!
        states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        continuation = c
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        continuation?.finish()
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            log.warning("DeviceMotion unavailable; staying .unknown")
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / sampleHz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.process(motion)
        }
        log.info("MountDetector started at \(self.sampleHz, format: .fixed(precision: 0)) Hz")
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        accelSamples.removeAll(keepingCapacity: true)
        stableSince = nil
        if state != .unknown {
            state = .unknown
            continuation?.yield(.unknown)
        }
        log.info("MountDetector stopped")
    }

    // MARK: - Sample handling

    private func process(_ motion: CMDeviceMotion) {
        let g = motion.gravity
        // Landscape: gravity has tiny y/z components → it points along
        // the device's x-axis (left/right edge).
        let isLandscape = abs(g.y) < 0.3 && abs(g.z) < 0.3

        let r = motion.rotationRate
        let rotMag = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        let stillRotation = rotMag < 0.05

        // Translational stillness: variance of userAcceleration over the
        // last 2 s. We use the SUMMED per-axis variance so a wobble in
        // any direction registers.
        let a = motion.userAcceleration
        accelSamples.append((a.x, a.y, a.z))
        let cap = Int(varianceWindow * sampleHz)
        if accelSamples.count > cap { accelSamples.removeFirst() }
        let accelVar = summedVariance(of: accelSamples)
        let stillAccel = accelVar < 0.005

        let qualifies = isLandscape && stillRotation && stillAccel

        let newState: State
        if !qualifies {
            stableSince = nil
            // Distinguish "almost there" from "actively moving": only the
            // instantaneous landscape + still-rotation gate fires .stable.
            if isLandscape && stillRotation {
                newState = .stable
            } else {
                newState = .moving
            }
        } else {
            if stableSince == nil { stableSince = Date() }
            let dur = Date().timeIntervalSince(stableSince!)
            newState = dur >= stabilityWindow ? .mounted : .stable
        }

        if newState != state {
            log.info("state \(self.state.rawValue) → \(newState.rawValue) (rot=\(rotMag, format: .fixed(precision: 3)) accVar=\(accelVar, format: .fixed(precision: 4)) landscape=\(isLandscape))")
            state = newState
            continuation?.yield(newState)
        }
    }

    private func summedVariance(of samples: [(x: Double, y: Double, z: Double)])
        -> Double {
        guard samples.count > 1 else { return 0 }
        let n = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.x } / n
        let my = samples.reduce(0) { $0 + $1.y } / n
        let mz = samples.reduce(0) { $0 + $1.z } / n
        var sum = 0.0
        for s in samples {
            let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
            sum += dx * dx + dy * dy + dz * dz
        }
        return sum / n
    }
}
