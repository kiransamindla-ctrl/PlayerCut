//
//  CaptureView.swift
//  PlayerCut/Capture
//
//  Launches the system Camera (UIImagePickerController) and hands the
//  recorded video to the highlight pipeline. PlayerCut no longer
//  configures AVCaptureSession, formats, codecs, color spaces, or
//  stabilization — the iPhone's own camera does that, identically to
//  the stock Camera app, because it IS the stock camera UI under the
//  hood.
//
//  Flow:
//    1. RootView presents CaptureView via fullScreenCover.
//    2. CaptureView wraps SystemCameraPicker (UIViewControllerRepresentable
//       around UIImagePickerController in camera/video mode).
//    3. The parent taps the system shutter to start, taps stop, taps
//       "Use Video". The picker delegate hands back info[.mediaURL].
//    4. handlePickedVideo copies the temp file into the app's working
//       directory (the picker's URL is in a system tmp that can be
//       reaped at any moment), saves a copy to Photos via the existing
//       PhotosLibraryService.saveSourceVideo (add-only), writes an
//       empty audio-loudness sidecar so Stage 1's existing decoder
//       doesn't trip, builds a GameSession, and hands it to
//       AppCoordinator.didFinishRecording — the same entry point the
//       previous custom-capture flow used.
//    5. CaptureView dismisses; the pipeline (Stage 1 → ranker →
//       compose) runs unchanged on the new source file.
//
//  Cancel path: the parent backs out of the picker without recording.
//  We dismiss the cover; no GameSession is created.
//

import AVFoundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os.log

struct CaptureView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let player: PlayerEnrollment

    @State private var sessionReelLength: ReelLength
    @State private var status: String = "Opening system camera…"
    @State private var working = false

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "CaptureUI")

    init(player: PlayerEnrollment) {
        self.player = player
        _sessionReelLength = State(initialValue: player.reelLengthPreference)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The picker presents itself full-screen as soon as this
            // view is on screen. Any time it's not active we show
            // status + a fallback "Open Camera" button (covers the
            // edge case where the picker is dismissed before recording
            // is fully ingested).
            if working {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                    Text(status)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                SystemCameraPicker(onComplete: handlePickedVideo)
                    .ignoresSafeArea()
            }
        }
    }

    /// Picker delegate result. `tempURL == nil` means cancel.
    private func handlePickedVideo(_ tempURL: URL?) {
        guard let tempURL else {
            log.info("system camera cancelled by user")
            dismiss()
            return
        }
        working = true
        status = "Saving video and starting highlight pipeline…"
        Task {
            await ingest(tempURL: tempURL)
            dismiss()
        }
    }

    /// 1. Copy the picker's temp video into our working directory so
    ///    Stage 1 can read it after iOS reaps the system tmp.
    /// 2. Save a copy to Photos via PhotosLibraryService.saveSourceVideo.
    /// 3. Write an empty audio-loudness sidecar JSON so Stage 1's
    ///    existing loudness decoder doesn't throw on the missing path.
    /// 4. Construct a GameSession and hand it to didFinishRecording —
    ///    the same entry point the custom-capture flow used. The
    ///    orchestrator picks it up from there.
    private func ingest(tempURL: URL) async {
        let id = UUID()
        let dir = StoragePaths.tempGameDirectory(for: id)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let workingURL = StoragePaths.tempRawVideoURL(for: id)
        let loudnessURL = StoragePaths.tempAudioLoudnessURL(for: id)

        do {
            try FileManager.default.copyItem(at: tempURL, to: workingURL)
        } catch {
            log.error("copy picker temp → working dir failed: \(error.localizedDescription)")
            return
        }

        // Empty loudness sidecar so Stage 1's existing decoder doesn't
        // trip on a missing file. The ranker's never-reject contract
        // (motion-only + Tier-3 montage) still produces a reel without
        // audio peaks.
        if let empty = try? JSONEncoder().encode([LoudnessSample]()) {
            try? empty.write(to: loudnessURL, options: .atomic)
        }

        // Save the original recording to Photos add-only. Best-effort —
        // if the user denies, the in-app reel still runs against the
        // working copy.
        let outcome = await PhotosLibraryService.saveSourceVideo(
            fileURL: tempURL)
        switch outcome {
        case .savedToAlbumAndRecents, .savedToRecents:
            log.info("saved source video to Photos")
            await DiagnosticsStore.shared
                .increment(.reelSavedToPhotosRecents)
        case .permissionDenied:
            log.warning("Photos add-only denied — source video stays in app sandbox only")
        case .failed(let msg):
            log.warning("Photos save failed: \(msg, privacy: .public)")
        }

        let game = GameSession(
            id: id,
            playerId: player.id,
            sport: player.sport,
            startedAt: Date(),
            endedAt: Date(),
            rawVideoURL: workingURL,
            audioLoudnessURL: loudnessURL,
            stage1Result: nil,
            stage2Result: nil,
            exportedReelAssetId: nil,
            localReelFallbackURL: nil,
            status: .awaitingProcessing,
            triggerSource: .manual,
            reelLengthOverride: sessionReelLength == player.reelLengthPreference
                ? nil : sessionReelLength,
            sceneType: .outdoor,
            captureRecipe: nil)
        await coordinator.didFinishRecording(game: game)
        await DiagnosticsStore.shared.increment(.gamesRecorded)
        log.info("system-camera ingest complete; game \(id.uuidString, privacy: .public) enqueued")
    }
}

// MARK: - System camera picker

/// SwiftUI wrapper around UIImagePickerController in camera/video
/// mode. We don't customize the camera UI — the parent sees the
/// system's own shutter / stop / "Use Video" buttons. That UI is
/// what guarantees the captured file is exactly stock-camera quality
/// (HEVC, P3, cinematic stabilization, the works).
struct SystemCameraPicker: UIViewControllerRepresentable {

    /// `URL` = the temp file the picker captured. `nil` = the user
    /// cancelled.
    let onComplete: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController,
                                context: Context) {
        // Nothing to update — the picker manages its own state.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject,
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onComplete: (URL?) -> Void
        init(onComplete: @escaping (URL?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info:
                [UIImagePickerController.InfoKey: Any]
        ) {
            let url = info[.mediaURL] as? URL
            picker.dismiss(animated: true) { [onComplete] in
                onComplete(url)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [onComplete] in
                onComplete(nil)
            }
        }
    }
}
