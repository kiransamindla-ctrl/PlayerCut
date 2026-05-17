//
//  CaptureView.swift
//  PlayerCut/Capture
//
//  Minimal capture UI for end-to-end on-device testing. Camera preview +
//  start/stop. Intentionally ugly — design pass comes later.
//

import AVFoundation
import SwiftUI
import os.log

struct CaptureView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let player: PlayerEnrollment

    @State private var isRecording = false
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var errorMessage: String?
    @State private var configured = false

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
        .onAppear {
            configureIfNeeded()
        }
        .onReceive(timer) { _ in
            if let startedAt {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button("Close") {
                if isRecording { stop() }
                dismiss()
            }
            .foregroundStyle(.white)
            Spacer()
            if isRecording {
                Text(formatElapsed(elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.7), in: Capsule())
            } else {
                Text("Recording for: \(player.name) #\(player.jerseyNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }

    private var bottomBar: some View {
        Button {
            if isRecording { stop() } else { start() }
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

    // MARK: - Actions

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

    private func start() {
        do {
            _ = try coordinator.captureController.startRecording(
                for: player,
                sport: player.sport)
            startedAt = Date()
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start: \(error.localizedDescription)"
            log.error("startRecording failed: \(error.localizedDescription)")
        }
    }

    private func stop() {
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
