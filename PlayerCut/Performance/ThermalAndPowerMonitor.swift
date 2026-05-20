//
//  ThermalAndPowerMonitor.swift
//  PlayerCut/Performance
//
//  Watches ProcessInfo for thermal and power-state changes. Stage 2
//  consults these to decide batch size and CoreML compute unit; the
//  UI surfaces a banner in GameDetailView when low-power mode would
//  defer heavy work.
//
//  This is intentionally lightweight — observers + a published state
//  the rest of the app can poll. Throttling actions live downstream.
//

import Combine
import Foundation
import os.log

@MainActor
final class ThermalAndPowerMonitor: ObservableObject {

    static let shared = ThermalAndPowerMonitor()

    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var lowPowerEnabled: Bool

    private let log = Logger(subsystem: "com.playercut.app", category: "Throttle")
    private var observers: [NSObjectProtocol] = []

    private init() {
        let info = ProcessInfo.processInfo
        self.thermalState = info.thermalState
        self.lowPowerEnabled = info.isLowPowerModeEnabled
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let s = ProcessInfo.processInfo.thermalState
                self.thermalState = s
                self.log.info("Thermal state → \(String(describing: s.rawValue))")
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let on = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.lowPowerEnabled = on
                self.log.info("Low-power mode → \(on)")
            }
        )
    }

    /// Stage 2 batch size scales down on heat. Tune later when we have
    /// real on-device thermal profiles from field tests.
    var recommendedStage2BatchSize: Int {
        switch thermalState {
        case .nominal, .fair: return 8
        case .serious:        return 4
        case .critical:       return 2
        @unknown default:     return 8
        }
    }

    /// True when we should defer non-critical processing.
    var shouldDeferHeavyWork: Bool {
        lowPowerEnabled || thermalState == .critical
    }
}
