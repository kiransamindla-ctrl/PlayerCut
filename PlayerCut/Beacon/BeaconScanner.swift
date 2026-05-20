//
//  BeaconScanner.swift
//  PlayerCut/Beacon
//
//  Core Bluetooth scanner for paired iBeacon-format trackers. Stage 2
//  consults this during ranking: when the player's paired beacon is
//  within configured proximity range, identification confidence is
//  forced to 1.0 and the OCR/face/color stack is skipped for those
//  frames. Out-of-range falls back to the normal identification stack.
//
//  Real beacon detection uses CoreLocation's CLBeaconRegion ranging,
//  but for this iteration we expose a CBCentralManager skeleton plus
//  an injectable scanner protocol so unit tests can drive a mock
//  without touching hardware.
//

import Combine
import CoreBluetooth
import Foundation
import os.log

/// Abstract scanner so MockBLEScanner can drive tests deterministically.
protocol BLEScanning: AnyObject {
    func startScanning(forBeaconUUID uuid: String)
    func stopScanning()
    /// AsyncStream of detection events as the scanner sees them.
    var detections: AsyncStream<BeaconDetection> { get }
}

struct BeaconDetection: Equatable {
    let uuid: String
    let proximity: Proximity
    let rssi: Int
    let timestamp: Date

    enum Proximity: String { case immediate, near, far, unknown }

    /// Sufficient confidence to skip the full ID stack.
    var isCloseEnoughToIdentify: Bool {
        proximity == .immediate || proximity == .near
    }
}

@MainActor
final class BeaconScanner: NSObject, BLEScanning, ObservableObject {

    let detections: AsyncStream<BeaconDetection>
    private var continuation: AsyncStream<BeaconDetection>.Continuation?

    private let log = Logger(subsystem: "com.playercut.app", category: "Beacon")
    private var central: CBCentralManager?
    private var targetUUID: String?

    override init() {
        var c: AsyncStream<BeaconDetection>.Continuation!
        detections = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { c = $0 }
        continuation = c
        super.init()
    }

    func startScanning(forBeaconUUID uuid: String) {
        targetUUID = uuid.uppercased()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn {
            beginScan()
        }
        log.info("Beacon scan requested for \(uuid)")
    }

    func stopScanning() {
        central?.stopScan()
        targetUUID = nil
        log.info("Beacon scan stopped")
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        // CBCentralManager scans for advertised services; iBeacon
        // ranging happens via CLBeaconRegion + CLLocationManager. The
        // present skeleton emits no detections — production ship needs
        // the CoreLocation ranging path. Marked TODO so it's greppable.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // TODO Beacon-LAUNCH: replace CBCentralManager scan with
        //   CLLocationManager.startRangingBeacons(satisfying:) on
        //   CLBeaconIdentityConstraint(uuid: targetUUID) and emit
        //   detections from locationManager(_:didRange:satisfying:).
    }
}

extension BeaconScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.info("CBCentralManager state → \(central.state.rawValue)")
            if central.state == .poweredOn { self.beginScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // No-op placeholder. iBeacon ranging proper lives behind the
        // CoreLocation API documented in startScanning above.
    }
}
