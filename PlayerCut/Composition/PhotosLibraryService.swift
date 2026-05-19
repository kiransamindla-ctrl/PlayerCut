//
//  PhotosLibraryService.swift
//  PlayerCut/Composition
//
//  Saves reels to the user's Photos library and reads them back.
//
//  Lives outside ReelComposer so the GameDetailView "Try again" path can
//  re-attempt the save without re-running the whole compose pipeline.
//

import Foundation
import Photos
import os.log

enum PhotosLibraryService {

    enum SaveResult {
        case saved(localIdentifier: String)
        case permissionDenied
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

    // MARK: - Save

    /// Saves `fileURL` into the PlayerCut album, creating the album if it
    /// doesn't exist yet. Returns `.permissionDenied` when the user has
    /// not granted add-only access; the caller is responsible for the
    /// retry path.
    static func saveReel(fileURL: URL,
                         albumTitle: String = defaultAlbumTitle) async -> SaveResult {
        var status = currentAddOnlyStatus
        if status == .notDetermined {
            status = await requestAddOnlyAuthorization()
        }
        guard status == .authorized || status == .limited else {
            log.warning("Photos add-only auth denied: \(status.rawValue)")
            await DiagnosticsStore.shared.increment(.photoLibraryPermissionDenied)
            return .permissionDenied
        }

        do {
            let album = try await fetchOrCreateAlbum(title: albumTitle)
            let localId = try await performSave(fileURL: fileURL, album: album)
            await DiagnosticsStore.shared.increment(.reelSavedToPhotos)
            log.info("Saved reel to '\(albumTitle)': \(localId)")
            return .saved(localIdentifier: localId)
        } catch {
            log.error("Photos save failed: \(error.localizedDescription)")
            return .permissionDenied
        }
    }

    // MARK: - Internals

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

    private static func performSave(fileURL: URL,
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

    // MARK: - Fetch back

    static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier],
                            options: nil).firstObject
    }
}
