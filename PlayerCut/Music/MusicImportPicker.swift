//
//  MusicImportPicker.swift
//  PlayerCut/Music
//
//  SwiftUI wrapper around UIDocumentPickerViewController filtered for
//  audio files. The wrapper handles iCloud Drive's security-scoped
//  URLs (start/stop access bracket) before handing the URL to
//  MusicImportManager.importTrack.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MusicImportPicker: UIViewControllerRepresentable {

    /// Fires with the picked URL when the user confirms a selection,
    /// or nil on cancel / error. Called on the main actor.
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Audio-only filter — UIDocumentPicker hides non-matching files
        // in the system Files app picker.
        let pc = UIDocumentPickerViewController(
            forOpeningContentTypes: [.audio, .mp3, .wav, .aiff],
            asCopy: true)
        pc.allowsMultipleSelection = false
        pc.shouldShowFileExtensions = true
        pc.delegate = context.coordinator
        return pc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // asCopy: true above means UIKit already copies the file into
            // a temp location and resolves the security scope for us, but
            // we still bracket for safety on older iOS paths.
            guard let url = urls.first else {
                onPick(nil)
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
