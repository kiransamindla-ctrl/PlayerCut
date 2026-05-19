//
//  MountDetector.swift
//  PlayerCut/Capture
//
//  Watches Core Motion to decide whether the phone is sitting on a tripod
//  in landscape, motionless, and ready to record. The capture UI uses this
//  to auto-start a session without requiring a tap.
//
//  Heuristics — tuned for "hand puts phone on tripod, walks 5 ft away":
//   - Orientation: gravity vector points mostly along ±x (landscape) with
//     small y/z components. Threshold 0.9 along x, 0.3 elsewhere.
//   - Angular stillness: instantaneous rotation-rate magnitude < 0.05 rad/s
//     for every sample in a 10-second rolling window.
//   - Translational stillness: variance of userAcceleration magnitude over
//     the rolling window stays under 0.01 g² (filters hand tremor).
//
//  The detector emits state transitions only — duplicate states are
//  swallowed so SwiftUI doesn't churn.
//

import Combine
import CoreMotion
import Foundation
import os.log

@MainActor
final class MountDetector: ObservableObject {

    enum State: String, Equatable {
        case unknown        // not started, or motion unavailable
        case moving         // hand-held / actively being repositioned
        case stable         // landscape + still, but not yet for 10s
        case mounted        // sustained stable → safe to auto-start
    }

    @Published private(set) var state: State = .unknown

    /// Seconds the detector needs to remain in `.stable` before promoting
    /// to `.mounted`. Exposed for tests / tuning, not for runtime change.
    let stabilityWindow: TimeInterval = 10.0

    private let motionManager = CMMotionManager()
    private let log = Logger(subsystem: "com.playercut.app", category: "Mount")
    private let sampleHz: Double = 20

    // Rolling window of user-acceleration magnitudes for variance.
    private var accelSamples: [Double] = []
    private var rotMagSamples: [Double] = []

    // First time we entered .stable in the current quiet streak. Reset to
    // nil whenever any qualifying condition fails.
    private var stableSince: Date?

    deinit {
        // Stop on the global queue — CMMotionManager is thread-safe for
        // this call and we can't reliably hop to main from deinit.
        motionManager.stopDeviceMotionUpdates()
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
        rotMagSamples.removeAll(keepingCapacity: true)
        stableSince = nil
        if state != .unknown { state = .unknown }
        log.info("MountDetector stopped")
    }

    // MARK: - Sample handling

    private func process(_ motion: CMDeviceMotion) {
        let g = motion.gravity
        let isLandscape = abs(g.x) > 0.9 && abs(g.y) < 0.3 && abs(g.z) < 0.3

        let r = motion.rotationRate
        let rotMag = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        let a = motion.userAcceleration
        let accMag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)

        appendRolling(rotMagSamples: rotMag, accelMag: accMag)

        let windowAngularStill =
            !rotMagSamples.isEmpty && rotMagSamples.allSatisfy { $0 < 0.05 }
        let accelVariance = variance(of: accelSamples)
        let windowAccelStill = accelVariance < 0.01

        let qualifies = isLandscape && windowAngularStill && windowAccelStill

        let newState: State
        if !qualifies {
            stableSince = nil
            // Distinguish "almost there" from "actively moving" — only the
            // instantaneous still + landscape gate fires `.stable`.
            if isLandscape && rotMag < 0.05 {
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
            log.info("state \(self.state.rawValue) → \(newState.rawValue) (rot=\(rotMag, format: .fixed(precision: 3)) accVar=\(accelVariance, format: .fixed(precision: 4)) landscape=\(isLandscape))")
            state = newState
        }
    }

    private func appendRolling(rotMagSamples rot: Double, accelMag: Double) {
        let cap = Int(stabilityWindow * sampleHz)  // 200 at 10s × 20Hz
        rotMagSamples.append(rot)
        if rotMagSamples.count > cap { rotMagSamples.removeFirst() }
        accelSamples.append(accelMag)
        if accelSamples.count > cap { accelSamples.removeFirst() }
    }

    private func variance(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sq = values.reduce(0) { acc, v in
            acc + (v - mean) * (v - mean)
        }
        return sq / Double(values.count)
    }
}
