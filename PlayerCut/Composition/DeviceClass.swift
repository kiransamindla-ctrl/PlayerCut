//
//  DeviceClass.swift
//  PlayerCut/Composition
//
//  Picks an EditPlanBuilder.PerfProfile based on the current device's
//  raw class (chip family) and live thermal state. The cinematic
//  pipeline is heavy — auto-reframe interpolation, custom CI
//  compositing, transitions, color grade, and overlay rendering all
//  add up. On A13/A14 or under .serious / .critical thermal we throttle:
//
//    - Crop keyframe density drops (less smooth pan but fewer
//      instructions to render)
//    - Heavy transitions (zoomPunch, lightLeakWipe) disabled in favor
//      of cross-dissolve
//    - Speed-ramp threshold raised so only the most exceptional clips
//      get slow-mo
//
//  All decisions are taken upfront before the EditPlan is built so the
//  renderer doesn't need to know about device class.
//

import Foundation
import UIKit

actor DeviceClass {

    static let shared = DeviceClass()

    /// Compute a perf profile suited to the current hardware + thermal
    /// state. Re-evaluated per-game; we don't cache so a hot phone
    /// recovers to high-end after a few games.
    func editProfile() -> EditPlanBuilder.PerfProfile {
        let thermal = ProcessInfo.processInfo.thermalState
        let chip = chipClass()

        // Thermal override wins — if the phone is sweating we don't
        // care what chip it has.
        switch thermal {
        case .critical, .serious:
            return .conservative
        case .fair:
            return chip.fairBudget
        case .nominal:
            return chip.nominalBudget
        @unknown default:
            return chip.nominalBudget
        }
    }

    // MARK: - Chip family

    private enum Chip {
        case a13a14       // iPhone 11 / 12 / SE2
        case a15a16       // iPhone 13 / 14 — minimum supported
        case a17plus      // iPhone 15 Pro and later

        var nominalBudget: EditPlanBuilder.PerfProfile {
            switch self {
            case .a13a14:    return .midRange
            case .a15a16:    return .highEnd
            case .a17plus:   return .highEnd
            }
        }
        var fairBudget: EditPlanBuilder.PerfProfile {
            switch self {
            case .a13a14:    return .conservative
            case .a15a16:    return .midRange
            case .a17plus:   return .highEnd
            }
        }
    }

    /// Best-effort chip family from `utsname.machine` string. New
    /// identifiers naturally fall into a17plus because we default the
    /// "unknown" case to the latest band, since the floor is iPhone 13
    /// (A15) by deployment target.
    private func chipClass() -> Chip {
        let id = machineIdentifier()
        // iPhone 11 family (A13)
        let a13Family = ["iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8"]
        // iPhone 12 family (A14) + SE 3rd gen
        let a14Family = ["iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4",
                         "iPhone14,6"]
        // iPhone 13 family (A15)
        let a15Family = ["iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
                         "iPhone14,7", "iPhone14,8"]
        // iPhone 14 Pro / 15 family (A16)
        let a16Family = ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5"]

        if a13Family.contains(id) || a14Family.contains(id) { return .a13a14 }
        if a15Family.contains(id) || a16Family.contains(id) { return .a15a16 }
        // Simulator + everything newer.
        return .a17plus
    }

    private func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        var id = ""
        for child in mirror.children {
            if let value = child.value as? Int8, value != 0 {
                id.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return id
    }
}
