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
//    5. selectedCamera, activeFormat, firstFrameReceived
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

    // ── configure() lifecycle ────────────────────────────────────
    @Published var configureStarted: Bool = false
    @Published var configureReturned: Bool = false

    // ── session.startRunning() observed value (Optional → nil =
    //    line never reached) ────────────────────────────────────
    @Published var startRunningSawIsRunning: Bool?

    // ── 3-second preview watchdog (Optional → nil = never fired) ─
    @Published var watchdogSawIsRunning: Bool?
    @Published var watchdogForcedRestart: Bool = false

    // ── Recipe outcome ────────────────────────────────────────────
    /// "pending" until applyRecipe runs; then
    /// "APPLIED 4k@60 hvc cinematic" / "FAILED: ..." / "NO FORMAT (running on default)".
    @Published var recipeOutcome: String = "pending"

    // ── First AVCaptureSessionRuntimeErrorNotification ───────────
    @Published var lastSessionRuntimeError: String?

    // ── Hardware / format ─────────────────────────────────────────
    @Published var resolvedTier: String = "?"
    @Published var selectedCamera: String = "(not picked)"
    @Published var liveSessionIsRunning: Bool = false
    @Published var liveActiveFormat: String = "(unknown)"

    /// True the first time the diagnostic AVCaptureVideoDataOutput
    /// delegate sees a sample buffer. Apple has documented that
    /// `session.isRunning == true` doesn't guarantee frames are
    /// flowing (developer.apple.com/forums/thread/811759); this is
    /// the only reliable proof the pipeline is alive.
    @Published var firstFrameReceived: Bool = false

    // ── Internals ─────────────────────────────────────────────────

    private var sessionErrorToken: NSObjectProtocol?

    /// Strong-held delegate for the diagnostic AVCaptureVideoDataOutput.
    /// Keeps the delegate alive while the session is configured.
    let firstFrameDelegate = FirstFrameDelegate()

    init() {
        firstFrameDelegate.debugInfo = self
    }

    /// Flip `firstFrameReceived` true exactly once. Called from the
    /// FirstFrameDelegate on its sample-buffer queue; nonisolated so
    /// the delegate doesn't need to hop to MainActor itself.
    nonisolated func markFirstFrameReceived() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.firstFrameReceived { self.firstFrameReceived = true }
        }
    }

    /// Install once per session lifecycle. Captures the first runtime
    /// error and freezes it on screen so the user can read it.
    func observeRuntimeErrors(on session: AVCaptureSession) {
        guard sessionErrorToken == nil else { return }
        sessionErrorToken = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session, queue: .main
        ) { [weak self] note in
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

// MARK: - First-frame delegate

/// Flips `CaptureDebugInfo.firstFrameReceived` true the first time
/// `AVCaptureVideoDataOutput` delivers a sample buffer.
final class FirstFrameDelegate: NSObject,
                                AVCaptureVideoDataOutputSampleBufferDelegate,
                                @unchecked Sendable {

    /// Weakly held back-reference so the delegate can flip the flag
    /// without retaining its owner.
    weak var debugInfo: CaptureDebugInfo?

    private let lock = NSLock()
    private var fired = false

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        guard shouldFire else { return }
        debugInfo?.markFirstFrameReceived()
        Logger(subsystem: "com.playercut.app", category: "Capture")
            .info("first frame received ✓")
    }
}
