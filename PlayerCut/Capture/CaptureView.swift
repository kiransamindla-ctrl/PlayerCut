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

    let player: PlayerEnrollment

    @AppStorage(SettingsKeys.autoStartEnabled) private var autoStartEnabled = true

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

    init(player: PlayerEnrollment) {
        self.player = player
        _sessionReelLength = State(initialValue: player.reelLengthPreference)
    }

    private let log = Logger(subsystem: "com.playercut.app", category: "CaptureUI")
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common)
        .autoconnect()

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
        }
        .onAppear { onAppear() }
        .onDisappear { onDisappear() }
        .onReceive(timer) { _ in
            if let startedAt {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    // MARK: - Lifecycle

    private func onAppear() {
        configureIfNeeded()
        if autoStartEnabled {
            mount.start()
            mountTask = Task { @MainActor in
                for await s in mount.states {
                    mountState = s
                    handleMountStateChange(s)
                }
            }
        }
    }

    private func onDisappear() {
        mount.stop()
        mountTask?.cancel()
        mountTask = nil
        autoStartTask?.cancel()
        autoStartTask = nil
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
            PCStatusChip(title: mountStatusLabel(mountState),
                         color: mountStatusColor(mountState))
                .padding(.bottom, 12)
        } else {
            PCStatusChip(title: "AUTO-START OFF — TAP RECORD",
                         color: Theme.bgCard.opacity(0.9))
                .padding(.bottom, 12)
        }
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

    private func mountStatusColor(_ s: MountDetector.State) -> Color {
        switch s {
        case .unknown, .moving: return Theme.bgCard.opacity(0.9)
        case .stable:           return Theme.accent
        case .mounted:          return Theme.success
        }
    }

    // MARK: - Mount detection wiring

    private func mountStatusLabel(_ s: MountDetector.State) -> String {
        switch s {
        case .unknown, .moving: return "DETECTING MOUNT"
        case .stable:           return "ALMOST READY"
        case .mounted:          return "MOUNTED"
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
            } catch {
                errorMessage = "Couldn't start: \(error.localizedDescription)"
                log.error("startRecording failed: \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        // Detect "user immediately killed an auto-start" → false positive.
        if let at = autoStartedAt, Date().timeIntervalSince(at) < 5 {
            Task { await DiagnosticsStore.shared.increment(.autoStartFalsePositive) }
        }
        autoStartedAt = nil
        isRecording = false
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
