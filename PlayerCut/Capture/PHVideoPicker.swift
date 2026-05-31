//
//  PHVideoPicker.swift
//  PlayerCut/Capture
//
//  CapCut-parity S4 — One-tap Instant Reel from existing video.
//  PHPickerViewController + PHPickerFilter.videos lets the parent drop
//  any clip from the camera roll instead of recording a fresh one.
//  Pipeline already handles any .mov/.mp4 (system-camera capture writes
//  the same shape today), so this is purely the entry point.
//

import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

/// Thin SwiftUI bridge to PHPickerViewController. Calls `onPicked` with
/// the picked video's local file URL (copied into the temp dir) or nil
/// on cancel / failure.
struct PHVideoPicker: UIViewControllerRepresentable {

    let onPicked: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let onPicked: (URL?) -> Void

        init(onPicked: @escaping (URL?) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { onPicked(nil); return }
            let provider = result.itemProvider
            // PHPicker hands us an NSItemProvider; loading the video as
            // file representation gives us a temp URL we own for the
            // lifetime of the callback. Copy into our temp dir so the
            // pipeline isn't racing the system's cleanup.
            let typeIdentifier = "public.movie"
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                onPicked(nil)
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier)
                { [onPicked] sourceURL, error in
                    guard let sourceURL else {
                        DispatchQueue.main.async { onPicked(nil) }
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("playercut-picked-\(UUID().uuidString).mov")
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: sourceURL, to: dest)
                        DispatchQueue.main.async { onPicked(dest) }
                    } catch {
                        DispatchQueue.main.async { onPicked(nil) }
                    }
                }
        }
    }
}
