//
//  MusicImportTests.swift
//  PlayerCutTests
//
//  BYO music import path — copy file into sandbox, run BPMDetector,
//  infer a vibe, persist the manifest, surface in MusicLibrary.
//  We use a bundled .m4a (energetic_1) staged into a temp directory
//  as the "external" pick so the test doesn't depend on UI plumbing.
//

import AVFoundation
import XCTest
@testable import PlayerCut

@MainActor
final class MusicImportTests: XCTestCase {

    /// Stable id per test so the cleanup hook is predictable.
    private var createdTrackIDs: [String] = []

    override func tearDown() async throws {
        for id in createdTrackIDs {
            MusicImportManager.shared.remove(id: id)
        }
        createdTrackIDs.removeAll()
        try await super.tearDown()
    }

    func testImportingBundledTrackProducesManifestEntryWithBPMAndVibe() async throws {
        let sourceURL = try stageBundledTrackToTemp(id: "energetic_1")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let beforeCount = MusicImportManager.shared.tracks.count
        let track = try await MusicImportManager.shared.importTrack(from: sourceURL)
        createdTrackIDs.append(track.id)

        XCTAssertEqual(MusicImportManager.shared.tracks.count, beforeCount + 1,
                       "imported track must land in the manager's list")
        XCTAssertTrue(track.id.hasPrefix("imported_"),
                      "imported ids must be prefixed for downstream gating")
        XCTAssertGreaterThan(track.duration, 5,
                             "duration probe should resolve > 5 s for a real track")
        XCTAssertNotNil(track.bpm, "BPMDetector should produce a non-fallback BPM for a clear bundled track")
        if let bpm = track.bpm {
            XCTAssertGreaterThanOrEqual(bpm, 60)
            XCTAssertLessThanOrEqual(bpm, 200)
        }
    }

    func testImportedTrackAppearsInMusicLibraryAllTracks() async throws {
        let sourceURL = try stageBundledTrackToTemp(id: "chill_1")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let track = try await MusicImportManager.shared.importTrack(from: sourceURL)
        createdTrackIDs.append(track.id)

        let combined = MusicLibrary.shared.allTracks
        let found = combined.first(where: { $0.id == track.id })
        XCTAssertNotNil(found, "MusicLibrary.allTracks must include imported entries")
        XCTAssertTrue(found?.isImported == true,
                      "imported track must surface with isImported = true")
        XCTAssertNotNil(found?.url, "imported track must resolve a sandbox URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: found!.url!.path),
                      "imported track file must exist on disk")
    }

    func testDeletingImportedTrackRemovesFileAndManifestEntry() async throws {
        let sourceURL = try stageBundledTrackToTemp(id: "playful_1")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let track = try await MusicImportManager.shared.importTrack(from: sourceURL)
        let sandboxPath = MusicImportManager.shared.url(for: track.id)!.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandboxPath))

        MusicImportManager.shared.remove(id: track.id)

        XCTAssertNil(MusicImportManager.shared.tracks.first(where: { $0.id == track.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandboxPath),
                       "removed track's sandbox file must be deleted")
    }

    func testUnsupportedFormatRejected() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).txt")
        try "hello".data(using: .utf8)?.write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        do {
            _ = try await MusicImportManager.shared.importTrack(from: bogus)
            XCTFail("import of .txt should throw")
        } catch let err as MusicImportManager.ImportError {
            switch err {
            case .unsupportedFormat: break  // expected
            default: XCTFail("expected .unsupportedFormat, got \(err)")
            }
        }
    }

    // MARK: - Persistence — newly-imported tracks survive a manager reload

    func testManifestPersistsAcrossManagerInstantiations() async throws {
        let sourceURL = try stageBundledTrackToTemp(id: "cinematic_1")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let track = try await MusicImportManager.shared.importTrack(from: sourceURL)
        createdTrackIDs.append(track.id)

        // We don't actually re-init the singleton (that requires test
        // hooks). Instead read the on-disk manifest directly to prove
        // we wrote it.
        let manifestPath = MusicImportManager.shared.importDirectory
            .appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestPath)
        let decoded = try JSONDecoder().decode([ImportedTrack].self, from: data)
        XCTAssertTrue(decoded.contains(where: { $0.id == track.id }),
                      "manifest.json on disk must contain the newly-imported track")
    }

    // MARK: - Helpers

    /// Copies a bundled .m4a to the test temp directory so we can drive
    /// the import flow with a non-bundle URL (same shape as UIDocumentPicker
    /// after asCopy: true).
    private func stageBundledTrackToTemp(id: String) throws -> URL {
        guard let src = Bundle.main.url(forResource: id, withExtension: "m4a") else {
            throw XCTSkip("bundled track \(id).m4a not reachable from test host")
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicimport-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}
