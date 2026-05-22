//
//  CaptureView.swift
//  PlayerCut/Capture
//
//  Minimal capture UI for end-to-end on-device testing. Camera preview +
//  start/stop, plus mount-detection auto-start. Intentionally ugly —
//  design pass comes later.
//

import AVFoundation
import SwiftUI
import os.log

struct CaptureView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let player: PlayerEnrollment

    // Mount auto-start is a *secondary* convenience. Default OFF so the
    // capture screen lands on a live preview + record button with zero
    // dependency on MountDetector — the spec calls this out explicitly.
    @AppStorage(SettingsKeys.autoStartEnabled) private var autoStartEnabled = false

    @State private var mount = MountDetector()
    @State private var mountState: MountDetector.State = .unknown
    @State private var mountTask: Task<Void, Never>?
    @State private var autoStartTask: Task<Void, Never>?
    @State private var autoStartCountdown: Int? = nil
    @State private var autoStartedAt: Date?     // for false-positive accounting

    @State private var isRecording = false
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var errorMessage: String?
    @State private var configured = false
    @State private var sessionReelLength: ReelLength
    @State private var showingLengthPicker = false
    @State private var armedPulse = false
    /// Whether the screen is currently dimmed by *this* CaptureView. The
    /// pre-dim brightness value itself lives in BrightnessKeeper so it
    /// survives scenePhase changes and even app termination — without
    /// that, backgrounding mid-record strands the screen at 10%.
    @State private var screenDimmed = false

    init(player: PlayerEnrollment) {
        self.player = player
        _sessionReelLength = State(initialValue: player.reelLengthPreference)
    }

    private let log = Logger(subsystem: "com.playercut.app", category: "CaptureUI")
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common)
        .autoconnect()
    /// TEMPORARY: 4 Hz tick refreshing the diagnostic overlay + polling
    /// session.isRunning. Remove with the overlay.
    @State private var debugTick: Date = Date()
    private let debugTimer = Timer.publish(every: 0.25,
                                           on: .main,
                                           in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: coordinator.captureController.session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                statusIndicator
                bottomBar
            }
            .padding()

            // TEMPORARY diagnostic overlay — read these values off the
            // phone screen and report back. Remove with this file's
            // changes once the preview-black regression is diagnosed.
            VStack(alignment: .leading, spacing: 3) {
                debugRow("session.isRunning",
                         coordinator.captureController.debugInfo
                            .liveSessionIsRunning ? "true" : "FALSE")
                debugRow("FRAME received",
                         coordinator.captureController.debugInfo
                            .firstFrameReceived ? "YES ✓" : "no — not flowing")
                debugRow("configured (View)",
                         configured ? "true" : "FALSE")
                debugRow("watchdog isRunning@3s",
                         debugBoolString(coordinator.captureController
                                            .debugInfo.watchdogSawIsRunning))
                debugRow("watchdog forced restart",
                         coordinator.captureController.debugInfo
                            .watchdogForcedRestart ? "YES" : "no")
                debugRow("recipe",
                         coordinator.captureController.debugInfo.recipeOutcome)
                debugRow("camera",
                         coordinator.captureController.debugInfo.selectedCamera)
                debugRow("active format",
                         coordinator.captureController.debugInfo.liveActiveFormat)
                debugRow("color space",
                         coordinator.captureController.debugInfo.colorSpace)
                debugRow("AVCaptureSession error",
                         coordinator.captureController.debugInfo
                            .lastSessionRuntimeError ?? "—")
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.78),
                        in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .topLeading)
            .padding(.top, 70)
            .padding(.leading, 12)
            .allowsHitTesting(false)

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding()
                        .background(Color.red.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }

            // Tap-to-wake overlay: while dimmed, any tap on the preview
            // restores brightness without stopping the recording so the
            // user can confirm framing without ending the game.
            if screenDimmed {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        BrightnessKeeper.restore()
                        screenDimmed = false
                    }
                    .accessibilityIdentifier("tap-to-wake")
                VStack {
                    Spacer()
                    Text("Recording — tap to brighten")
                        .font(.pcCaption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 140)
                }
            }
        }
        .onAppear { onAppear() }
        .onDisappear { onDisappear() }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .onReceive(timer) { _ in
            if let startedAt {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        .onReceive(debugTimer) { now in
            // TEMPORARY: poll live session.isRunning + the device's
            // current activeFormat into the observed debugInfo so the
            // overlay reflects the real state of the AV pipeline
            // independent of any single-shot snapshot from configure()
            // or the watchdog.
            let ctrl = coordinator.captureController
            ctrl.debugInfo.liveSessionIsRunning = ctrl.session.isRunning
            ctrl.debugInfo.liveActiveFormat = ctrl.currentActiveFormatDescription()
            debugTick = now
        }
    }

    // MARK: - Diagnostic overlay helpers (TEMPORARY)

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .frame(width: 165, alignment: .leading)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func debugBoolString(_ b: Bool?) -> String {
        switch b {
        case .none:        return "—"
        case .some(true):  return "true"
        case .some(false): return "FALSE"
        }
    }

    /// Restore brightness immediately on any leave-active transition so
    /// the user doesn't land in another app or on the home screen with
    /// their phone stuck at 10%. On return to .active, only re-dim if a
    /// recording is still in progress.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if isRecording && !screenDimmed {
                BrightnessKeeper.dim()
                screenDimmed = true
            }
        case .inactive, .background:
            if screenDimmed {
                BrightnessKeeper.restore()
                screenDimmed = false
            }
        @unknown default:
            break
        }
    }

    // MARK: - Lifecycle

    private func onAppear() {
        log.info("CaptureView onAppear autoStartEnabled=\(autoStartEnabled)")
        // Permission first: AVCaptureDevice creation silently fails if
        // the user hasn't granted access, surfacing as a useless
        // "PipelineError error 0" on the capture screen. Request both
        // (camera AND mic — capture session needs both) explicitly
        // before we touch the capture controller.
        Task { @MainActor in
            let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK    = await AVCaptureDevice.requestAccess(for: .audio)
            if !cameraOK || !micOK {
                errorMessage = "Camera and microphone access are required. " +
                    "Enable them in Settings → PlayerCut."
                log.error("Permission denied: camera=\(cameraOK) mic=\(micOK)")
                return
            }
            configureIfNeeded()
            schedulePreviewWatchdog()
        }
        // MountDetector is opt-in. When auto-start is OFF (default) we
        // never even spin up CMMotionManager — the capture screen is
        // pure manual record. When ON, mount detection runs ALONGSIDE
        // the manual button, never replacing it.
        if autoStartEnabled {
            log.info("auto-start ON → starting MountDetector")
            mount.start()
            mountTask = Task { @MainActor in
                for await s in mount.states {
                    mountState = s
                    handleMountStateChange(s)
                }
            }
        } else {
            log.info("auto-start OFF → MountDetector skipped")
        }
    }

    /// Three-second watchdog per spec: if the AVCaptureSession isn't
    /// running by the time the user can reasonably expect a preview,
    /// force-restart it. The controller logs both branches so we can
    /// tell whether the recipe-application path stalled the session
    /// (vs. a permission issue or hardware gripe).
    private func schedulePreviewWatchdog() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard configured else {
                log.warning("preview watchdog: configure() never completed")
                return
            }
            if coordinator.captureController.session.isRunning {
                log.info("preview watchdog: session.isRunning=true ✓")
            } else {
                log.error("preview watchdog: session NOT running after 3s — forcing restart")
                coordinator.captureController.forceRestartIfStalled()
            }
        }
    }

    private func onDisappear() {
        mount.stop()
        mountTask?.cancel()
        mountTask = nil
        autoStartTask?.cancel()
        autoStartTask = nil
        // Defensive: if we leave mid-recording (rare — Close already
        // calls stop) make sure brightness + idle timer aren't left
        // in capture mode.
        restorePowerProfile()
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack(alignment: .top) {
            // Length pill (left). Disabled mid-record so we don't change
            // targets on a session that's already counting down.
            Button {
                Haptic.tap()
                showingLengthPicker = true
            } label: {
                Text(sessionReelLength.rawValue.uppercased())
                    .font(.system(size: 16, weight: .black))
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.bgCard.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRecording)
            .opacity(isRecording ? 0.4 : 1)
            .confirmationDialog("Reel length",
                                isPresented: $showingLengthPicker,
                                titleVisibility: .visible) {
                ForEach(ReelLength.allCases, id: \.self) { length in
                    Button(length.displayName) { sessionReelLength = length }
                }
            }

            Spacer()

            Button {
                Haptic.tap()
                if isRecording { stop() }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isRecording {
            PCStatusChip(title: "● RECORDING  \(formatElapsed(elapsed))",
                         color: Theme.danger)
                .padding(.bottom, 12)
        } else if let n = autoStartCountdown {
            VStack(spacing: 12) {
                PCStatusChip(title: "MOUNTED — STARTING IN \(n)",
                             color: Theme.success)
                Button {
                    Haptic.warning()
                    cancelAutoStartByUser()
                } label: {
                    Text("CANCEL")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.4)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .foregroundStyle(Theme.textPrimary)
                        .overlay(Capsule().stroke(Theme.textPrimary, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)
        } else if autoStartEnabled {
            // Quiet hint, not a blocking status chip. The record button
            // is the primary action even when auto-start is on.
            Text(mountHintLabel(mountState))
                .font(.pcCaption)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.bottom, 12)
        }
        // Auto-start off: no status chip. The pulsing red record
        // button below is the only call to action.
    }

    private var bottomBar: some View {
        Button {
            if isRecording { Haptic.warning(); stop() }
            else { start(trigger: .manual) }
        } label: {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Theme.textPrimary.opacity(0.9), lineWidth: 5)
                    .frame(width: 96, height: 96)
                // Inner fill — square when recording, circle when armed
                if isRecording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.danger)
                        .frame(width: 38, height: 38)
                } else {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 80, height: 80)
                        .scaleEffect(armedPulse ? 1.0 : 0.94)
                        .animation(.easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true),
                                   value: armedPulse)
                        .onAppear { armedPulse = true }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!configured)
        .opacity(configured ? 1 : 0.4)
        .padding(.bottom, 8)
    }

    // MARK: - Mount detection wiring (auto-start opt-in)

    /// Quiet, non-blocking hint used only when auto-start is enabled.
    /// Never says "DETECTING MOUNT" front-and-center — the spec wants
    /// the record button to be the primary action; mount status is a
    /// secondary convenience.
    private func mountHintLabel(_ s: MountDetector.State) -> String {
        switch s {
        case .unknown, .moving: return "Auto-start: waiting for mount"
        case .stable:           return "Auto-start: almost ready"
        case .mounted:          return "Auto-start: mounted"
        }
    }

    private func handleMountStateChange(_ s: MountDetector.State) {
        guard !isRecording else { return }
        switch s {
        case .mounted:
            beginAutoStartCountdown()
        case .moving, .unknown:
            // Lost the mount before countdown finished — abort.
            cancelAutoStart()
        case .stable:
            break
        }
    }

    private func beginAutoStartCountdown() {
        guard autoStartTask == nil else { return }
        autoStartCountdown = 3
        autoStartTask = Task { @MainActor in
            for n in stride(from: 3, through: 1, by: -1) {
                autoStartCountdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if mountState != .mounted {
                    autoStartCountdown = nil
                    autoStartTask = nil
                    return
                }
            }
            autoStartCountdown = nil
            autoStartTask = nil
            start(trigger: .mountDetected)
        }
    }

    /// User-initiated cancel from the on-screen Cancel button. Counts as
    /// a false positive so we can track over-eager mount detection.
    private func cancelAutoStartByUser() {
        Task { await DiagnosticsStore.shared.increment(.autoStartFalsePositive) }
        cancelAutoStart()
    }

    private func cancelAutoStart() {
        autoStartTask?.cancel()
        autoStartTask = nil
        autoStartCountdown = nil
    }

    // MARK: - Recording lifecycle

    private func configureIfNeeded() {
        guard !configured else { return }
        do {
            try coordinator.captureController.configure()
            configured = true
        } catch {
            errorMessage = "Camera setup failed: \(error.localizedDescription)"
            log.error("Camera configure failed: \(error.localizedDescription)")
        }
    }

    private func start(trigger: TriggerSource) {
        let override: ReelLength? = (sessionReelLength == player.reelLengthPreference)
            ? nil : sessionReelLength
        // startRecording is async because it does a pre-flight scene-
        // luminance sample before locking white balance. Kick it off in
        // a Task so the SwiftUI handler stays sync.
        Task {
            do {
                _ = try await coordinator.captureController.startRecording(
                    for: player,
                    sport: player.sport,
                    triggerSource: trigger,
                    reelLengthOverride: override)
                startedAt = Date()
                isRecording = true
                errorMessage = nil
                if trigger == .mountDetected {
                    autoStartedAt = Date()
                    await DiagnosticsStore.shared.increment(.autoStartTriggered)
                } else {
                    autoStartedAt = nil
                }
                applyCapturePowerProfile()
            } catch {
                errorMessage = "Couldn't start: \(error.localizedDescription)"
                log.error("startRecording failed: \(error.localizedDescription)")
            }
        }
    }

    /// B1 + B2: keep the screen awake on the tripod and dim it so an
    /// hour-long sideline recording doesn't burn the battery just to
    /// drive a 600-nit panel nobody is looking at.
    private func applyCapturePowerProfile() {
        UIApplication.shared.isIdleTimerDisabled = true
        BrightnessKeeper.dim()
        screenDimmed = true
        Task { await DiagnosticsStore.shared.increment(.idleTimerDisabledDuringCapture) }
    }

    private func restorePowerProfile() {
        UIApplication.shared.isIdleTimerDisabled = false
        if screenDimmed || BrightnessKeeper.isDimmed {
            BrightnessKeeper.restore()
            screenDimmed = false
        }
    }

    private func stop() {
        // Detect "user immediately killed an auto-start" → false positive.
        if let at = autoStartedAt, Date().timeIntervalSince(at) < 5 {
            Task { await DiagnosticsStore.shared.increment(.autoStartFalsePositive) }
        }
        autoStartedAt = nil
        isRecording = false
        restorePowerProfile()
        Task {
            do {
                let game = try await coordinator.captureController.stopRecording()
                await coordinator.didFinishRecording(game: game)
                dismiss()
            } catch {
                errorMessage = "Couldn't stop: \(error.localizedDescription)"
                log.error("stopRecording failed: \(error.localizedDescription)")
            }
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Preview layer bridge

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // Force-cast is safe because layerClass is hard-coded above.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
