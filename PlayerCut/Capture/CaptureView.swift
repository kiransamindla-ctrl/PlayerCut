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
            VStack(alignment: .leading, spacing: 6) {
                Button("Close") {
                    if isRecording { stop() }
                    dismiss()
                }
                .foregroundStyle(.white)

                // Per-game reel length override. Disabled mid-record so
                // we don't change targets on a session that's already
                // counting down.
                Button {
                    showingLengthPicker = true
                } label: {
                    Label(sessionReelLength.rawValue, systemImage: "ruler")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)
                .disabled(isRecording)
                .confirmationDialog("Reel length",
                                    isPresented: $showingLengthPicker,
                                    titleVisibility: .visible) {
                    ForEach(ReelLength.allCases, id: \.self) { length in
                        Button(length.displayName) { sessionReelLength = length }
                    }
                }
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if isRecording {
                    Text(formatElapsed(elapsed))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.7), in: Capsule())
                } else {
                    // Small fallback manual-start button — always available
                    // regardless of whether auto-start is enabled.
                    Button {
                        cancelAutoStart()
                        start(trigger: .manual)
                    } label: {
                        Label("Start", systemImage: "record.circle")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!configured)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isRecording {
            Label("Recording", systemImage: "circle.fill")
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
        } else if let n = autoStartCountdown {
            VStack(spacing: 8) {
                Text("Mounted! Starting in \(n)…")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.85), in: Capsule())
                Button("Cancel auto-start") { cancelAutoStartByUser() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.bottom, 12)
        } else if autoStartEnabled {
            Text(mountStatusLabel(mountState))
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
        } else {
            Text("Auto-start disabled — tap Start")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
        }
    }

    private var bottomBar: some View {
        Button {
            if isRecording { stop() } else { start(trigger: .manual) }
        } label: {
            Text(isRecording ? "Stop" : "Start")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .gray : .red)
        .disabled(!configured)
    }

    // MARK: - Mount detection wiring

    private func mountStatusLabel(_ s: MountDetector.State) -> String {
        switch s {
        case .unknown, .moving: return "Hold steady — detecting mount…"
        case .stable:           return "Almost ready…"
        case .mounted:          return "Mounted"
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
        do {
            let override: ReelLength? = (sessionReelLength == player.reelLengthPreference)
                ? nil : sessionReelLength
            _ = try coordinator.captureController.startRecording(
                for: player,
                sport: player.sport,
                triggerSource: trigger,
                reelLengthOverride: override)
            startedAt = Date()
            isRecording = true
            errorMessage = nil
            if trigger == .mountDetected {
                autoStartedAt = Date()
                Task { await DiagnosticsStore.shared.increment(.autoStartTriggered) }
            } else {
                autoStartedAt = nil
            }
        } catch {
            errorMessage = "Couldn't start: \(error.localizedDescription)"
            log.error("startRecording failed: \(error.localizedDescription)")
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
