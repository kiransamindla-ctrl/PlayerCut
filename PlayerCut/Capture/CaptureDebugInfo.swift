//
//  CaptureDebugInfo.swift
//  PlayerCut/Capture
//
//  TEMPORARY on-device diagnostic. Surfaces the values the user
//  needs to read off the phone screen when Console.app / idevicesyslog
//  aren't practical:
//
//    1. configure() session.startRunning() returned, isRunning = ?
//    2. preview watchdog: session.isRunning = ?
//    3. recipe: APPLIED <res>@<fps> / FAILED <reason> / pending
//    4. any AVCaptureSession runtime error
//
//  Lives as an ObservableObject on the capture controller. The
//  CaptureView reads it in an overlay so it renders on top of the
//  preview (which may be black). Remove this file and the overlay
//  binding once the preview-black regression is diagnosed and fixed.
//

import AVFoundation
import Combine
import Foundation
import os.log

@MainActor
final class CaptureDebugInfo: ObservableObject {

    /// configure() phases. `nil` = the line never executed; bool = the
    /// value we read at that line.
    @Published var configureStarted: Bool = false
    @Published var configureReturned: Bool = false

    /// Captured at the moment `session.startRunning()` returns from
    /// inside configure()'s Phase 1 dispatch. `nil` until the dispatch
    /// actually executes.
    @Published var startRunningSawIsRunning: Bool?

    /// Set by the 3-second preview watchdog in CaptureView. `nil` until
    /// the watchdog runs.
    @Published var watchdogSawIsRunning: Bool?
    /// True iff the watchdog hit the `forceRestartIfStalled()` path.
    @Published var watchdogForcedRestart: Bool = false

    /// Recipe outcome from `applyRecipeBestEffort`.
    /// "" = never ran yet; "APPLIED 4k@60 hvc cinematic" / "FAILED: ..."
    @Published var recipeOutcome: String = "pending"

    /// First AVCaptureSession runtime error we observed via
    /// NSNotification, or `nil` if the session has never reported one.
    @Published var lastSessionRuntimeError: String?

    /// SoC tier as DeviceCapabilities resolved it at configure().
    @Published var resolvedTier: String = "?"

    /// Live `session.isRunning` polled by the view. Set from the view
    /// because polling AVCaptureSession.isRunning is cheap and reading
    /// it inside the controller closures would require explicit
    /// scheduling.
    @Published var liveSessionIsRunning: Bool = false

    private var sessionErrorToken: NSObjectProtocol?

    /// Install once per session lifecycle. Captures the first runtime
    /// error and freezes it on screen so the user can read it.
    func observeRuntimeErrors(on session: AVCaptureSession) {
        guard sessionErrorToken == nil else { return }
        sessionErrorToken = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session, queue: .main
        ) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let text = err.map { "\($0.domain) \($0.code) — \($0.localizedDescription)" }
                ?? "runtime error (no userInfo)"
            Task { @MainActor [weak self] in
                self?.lastSessionRuntimeError = text
            }
            Logger(subsystem: "com.playercut.app",
                   category: "CaptureDbg")
                .error("AVCaptureSessionRuntimeError: \(text, privacy: .public)")
        }
    }
}
