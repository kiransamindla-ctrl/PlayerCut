//
//  PhotosLibraryService.swift
//  PlayerCut/Composition
//
//  Saves a *copy* of the finished reel to the user's Photos library.
//  The canonical playback source lives in Documents/reels/ — Photos
//  is opt-in delivery, not the source of truth.
//
//  Permission model (least privilege):
//   - Request PHPhotoLibrary.requestAuthorization(for: .addOnly).
//   - Under .addOnly or .authorized: PHAssetCreationRequest copies the
//     file into the library. It lands in Recents. We never try to
//     read the asset back — that would fail under add-only and is
//     unnecessary because the local sandbox file is the canonical
//     copy used by playback.
//   - Under .authorized (full) only: attempt to also add the asset to
//     a "PlayerCut" album. Album creation/insertion failures are
//     non-fatal; the Recents save already succeeded.
//   - Under .denied / .restricted: skip Photos. Caller surfaces a
//     banner with a Settings deeplink.
//

import Foundation
import Photos
import os.log

enum PhotosLibraryService {

    enum SaveOutcome {
        case savedToAlbumAndRecents(localIdentifier: String?)
        case savedToRecents(localIdentifier: String?)
        case permissionDenied
        case failed(String)
    }

    /// Stable string for diagnostics enum logging.
    enum AuthStatusLabel: String, RawRepresentable {
        case notDetermined, restricted, denied, authorized, limited, addOnly, unknown
    }

    static let defaultAlbumTitle = "PlayerCut"
    static let compilationAlbumTitle = "PlayerCut Compilations"
    private static let log = Logger(subsystem: "com.playercut.app",
                                    category: "Photos")

    // MARK: - Authorization

    static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    static var currentAddOnlyStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Read-write authorization status. We NEVER request this — the app
    /// is designed to be add-only. But we read the current status so we
    /// can tell whether a read-back (album listing, asset fetch) is
    /// safe: read APIs on PHPhotoLibrary crash without the
    /// NSPhotoLibraryUsageDescription Info.plist key when called under
    /// add-only authorization, even though the user "granted" access.
    /// Only `.authorized` and `.limited` here mean reads are safe.
    static var currentReadWriteStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// True iff the library can be READ from this process without a
    /// privacy-violation crash. Add-only never grants this.
    static var hasReadAccess: Bool {
        let s = currentReadWriteStatus
        return s == .authorized || s == .limited
    }

    static func label(for status: PHAuthorizationStatus) -> AuthStatusLabel {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .limited:       return .limited
        @unknown default:    return .unknown
        }
    }

    // MARK: - Save

    /// Copies `fileURL` into the user's Photos library. Optionally
    /// tries the named album when full access is granted. Always
    /// hits Recents under add-only or full access.
    static func saveReel(fileURL: URL,
                         albumTitle: String = defaultAlbumTitle) async -> SaveOutcome {
        var status = currentAddOnlyStatus
        if status == .notDetermined {
            status = await requestAddOnlyAuthorization()
        }
        await DiagnosticsStore.shared.recordEnum(.photoAuthStatusAtSave,
                                                 value: label(for: status))

        guard status == .authorized || status == .limited else {
            log.warning("Photos add-only auth denied: \(status.rawValue)")
            await DiagnosticsStore.shared.increment(.photoLibraryPermissionDenied)
            return .permissionDenied
        }

        // Step 1 (required): land a copy in the library. Under add-only
        // this is the only thing we get to do.
        let recentsId: String?
        do {
            recentsId = try await performRecentsSave(fileURL: fileURL)
            log.info("Saved reel to Photos Recents: \(recentsId ?? "<no id>")")
            await DiagnosticsStore.shared.increment(.reelSavedToPhotosRecents)
        } catch {
            log.error("Photos Recents save failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        // Step 2 (optional, full access only): also add to album.
        // CRITICAL: the previous gate was `status == .authorized`
        // where `status` came from authorizationStatus(for: .addOnly).
        // That `.authorized` means "add-only authorized," NOT
        // "read-write authorized" — but the album branch calls
        // PHAssetCollection.fetchAssetCollections (a READ), which
        // crashes the process without NSPhotoLibraryUsageDescription
        // under add-only. We now gate on `hasReadAccess`, which
        // queries authorizationStatus(for: .readWrite) directly and
        // only returns true under full / limited read-write access.
        guard hasReadAccess else {
            log.info("Skipping album save — only add-only authorization (read APIs would crash)")
            return .savedToRecents(localIdentifier: recentsId)
        }
        do {
            let album = try await fetchOrCreateAlbum(title: albumTitle)
            // Re-create with album link in one transaction so we get
            // an album-aware placeholder if the prior Recents save
            // didn't return an id.
            let albumId = try await performAlbumLinkedSave(fileURL: fileURL,
                                                           album: album)
            await DiagnosticsStore.shared.increment(.reelSavedToPlayerCutAlbum)
            log.info("Also added reel to '\(albumTitle)' album: \(albumId)")
            return .savedToAlbumAndRecents(localIdentifier: albumId)
        } catch {
            // Album save is best-effort; the Recents copy already
            // happened so the user has their reel.
            log.warning("Album save fell back to Recents-only: \(error.localizedDescription)")
            return .savedToRecents(localIdentifier: recentsId)
        }
    }

    // MARK: - Internals: Recents save (add-only safe)

    private static func performRecentsSave(fileURL: URL) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                if let req = PHAssetCreationRequest
                    .creationRequestForAssetFromVideo(atFileURL: fileURL) {
                    placeholder = req.placeholderForCreatedAsset
                }
            } completionHandler: { ok, error in
                if !ok {
                    cont.resume(throwing: error
                        ?? NSError(domain: "PhotosLibraryService", code: 5))
                    return
                }
                // Under .addOnly, placeholder?.localIdentifier may not
                // be readable later — that's fine, we don't depend on it.
                cont.resume(returning: placeholder?.localIdentifier)
            }
        }
    }

    // MARK: - Internals: album save (full access only)

    private static func fetchOrCreateAlbum(title: String) async throws -> PHAssetCollection {
        if let existing = fetchAlbum(title: title) { return existing }
        return try await withCheckedThrowingContinuation { cont in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title)
                placeholder = req.placeholderForCreatedAssetCollection
            } completionHandler: { ok, error in
                if !ok {
                    cont.resume(throwing: error
                        ?? NSError(domain: "PhotosLibraryService", code: 1))
                    return
                }
                guard let id = placeholder?.localIdentifier,
                      let collection = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [id],
                        options: nil).firstObject else {
                    cont.resume(throwing: NSError(domain: "PhotosLibraryService",
                                                  code: 2))
                    return
                }
                cont.resume(returning: collection)
            }
        }
    }

    private static func fetchAlbum(title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album,
                                                       subtype: .any,
                                                       options: options).firstObject
    }

    private static func performAlbumLinkedSave(fileURL: URL,
                                               album: PHAssetCollection) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                guard let creation = PHAssetCreationRequest
                    .creationRequestForAssetFromVideo(atFileURL: fileURL) else {
                    return
                }
                placeholder = creation.placeholderForCreatedAsset
                if let placeholder,
                   let albumChange = PHAssetCollectionChangeRequest(for: album) {
                    albumChange.addAssets([placeholder] as NSFastEnumeration)
                }
            } completionHandler: { ok, error in
                if !ok {
                    cont.resume(throwing: error
                        ?? NSError(domain: "PhotosLibraryService", code: 3))
                    return
                }
                guard let id = placeholder?.localIdentifier else {
                    cont.resume(throwing: NSError(domain: "PhotosLibraryService",
                                                  code: 4))
                    return
                }
                cont.resume(returning: id)
            }
        }
    }

    // MARK: - Fetch back (full-access only, not on the playback path)

    /// Best-effort PHAsset lookup. Returns nil under add-only. Used by
    /// the compilation path that already requires resolvable assets,
    /// NOT by the per-game playback path (which uses localReelURL).
    ///
    /// Belt-and-braces: PHAsset.fetchAssets is a READ API and crashes
    /// the process without NSPhotoLibraryUsageDescription. We short-
    /// circuit with `hasReadAccess` so the compilation path can never
    /// trip the same crash that the album branch did.
    static func fetchAsset(localIdentifier: String) -> PHAsset? {
        guard hasReadAccess else {
            log.info("fetchAsset skipped — no read-write authorization")
            return nil
        }
        return PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier],
                                   options: nil).firstObject
    }
}
