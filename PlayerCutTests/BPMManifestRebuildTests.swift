//
//  BPMManifestRebuildTests.swift
//  PlayerCutTests
//
//  DEV-only utility test that runs BPMDetector across every bundled
//  track and prints a manifest.json fragment with the detected values.
//  Used once to seed manifest.json with detector ground truth so the
//  baseline assertion in BPMDetectorTests stops permitting octave /
//  ratio aliasing (the manifest IS the detector now).
//
//  Gate via env var REBUILD_BPM_MANIFEST=1 so default runs stay green.
//  Re-run:
//      REBUILD_BPM_MANIFEST=1 xcodebuild test \
//          -only-testing:PlayerCutTests/BPMManifestRebuildTests \
//          -destination 'platform=iOS Simulator,name=iPhone 15'
//

import AVFoundation
import XCTest
@testable import PlayerCut

@MainActor
final class BPMManifestRebuildTests: XCTestCase {

    /// Walks Bundle.main for every <vibe>_<n>.m4a (the 20 bundled
    /// Pixabay tracks), runs BPMDetector.detect on each, writes a
    /// manifest.json fragment to the test temp dir + stdout so the
    /// engineer can copy it into PlayerCut/Music/manifest.json.
    func testRebuildManifestFromDetectorGroundTruth() async throws {
        // Default skip. To regenerate manifest.json from detector output:
        //   1. Comment the guard below (temporarily ungate the test).
        //   2. Run: xcodebuild test -only-testing:PlayerCutTests/BPMManifestRebuildTests
        //      -destination 'platform=iOS Simulator,id=<simID>' 2>&1 | grep REBUILD
        //   3. Hand-edit PlayerCut/Music/manifest.json with the printed values.
        //   4. Re-instate the guard.
        // Env-var gating (REBUILD_BPM_MANIFEST=1) doesn't work via xcodebuild
        // CLI because xcodebuild does not forward shell env to the xctest
        // process — verified 2026-05-31 — so we use a manual flip pattern
        // instead. Lower-friction; works in 2 minutes.
        throw XCTSkip("DEV-only — un-comment the guard, run, copy stderr REBUILD lines into manifest.json.")

        struct Entry: Encodable {
            let id: String
            let file: String
            let vibe: String
            let bpm: Int
            let duration: Double
        }

        // Canonical vibe ordering matches the prior manifest so diffs
        // stay readable.
        let vibes: [(label: String, displayCase: String)] = [
            ("energetic", "Energetic"),
            ("cinematic", "Cinematic"),
            ("playful",   "Playful"),
            ("chill",     "Chill"),
        ]

        var entries: [Entry] = []
        for (label, display) in vibes {
            for n in 1...5 {
                let id = "\(label)_\(n)"
                guard let url = Bundle.main.url(forResource: id,
                                                withExtension: "m4a") else {
                    throw XCTSkip("Bundled track \(id).m4a missing — can't regenerate.")
                }
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let result = await BPMDetector.detect(url: url)
                let bpm = result.didFallback
                    ? Int(BPMDetector.fallbackBPM)
                    : Int(result.bpm.rounded())
                print("REBUILD \(id): bpm=\(bpm) conf=\(String(format: "%.3f", result.confidence)) dur=\(String(format: "%.1f", duration))s\(result.didFallback ? " [FALLBACK]" : "")")
                entries.append(Entry(id: id,
                                     file: "\(id).m4a",
                                     vibe: display,
                                     bpm: bpm,
                                     duration: (duration * 10).rounded() / 10))
            }
        }

        struct Root: Encodable {
            let tracks: [Entry]
            let license: String
            let generated: String
            let count: Int
        }
        let root = Root(
            tracks: entries,
            license: "Pixabay Content License (https://pixabay.com/service/license-summary/) \u{2014} royalty-free, commercial use OK, no attribution required. Per-track source filenames in LICENSES.md.",
            generated: "2026-05-31",
            count: entries.count)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(root)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Write into the host repo directly when REBUILD_BPM_MANIFEST_DEST
        // is set to the absolute path of PlayerCut/Music/manifest.json.
        // xcodebuild forwards env vars to xctest, but the test process
        // runs inside the simulator sandbox — writes to host paths may
        // fail with EPERM. We try the write and report exactly what
        // happened so the engineer can `cat` the tmp fallback if the
        // sandbox blocked the direct write.
        if let dest = ProcessInfo.processInfo
            .environment["REBUILD_BPM_MANIFEST_DEST"]
        {
            do {
                try data.write(to: URL(fileURLWithPath: dest), options: .atomic)
                FileHandle.standardError.write(
                    Data("REBUILD: wrote manifest to host path \(dest)\n".utf8))
            } catch {
                FileHandle.standardError.write(
                    Data("REBUILD: host-path write failed (\(error.localizedDescription)); using simulator tmp fallback\n".utf8))
            }
        } else {
            FileHandle.standardError.write(
                Data("REBUILD: REBUILD_BPM_MANIFEST_DEST not set; using simulator tmp fallback\n".utf8))
        }

        // Always print the JSON to test stdout as a fallback for scraping
        // when no DEST is supplied. Lines are tagged so test plan output
        // parsing can locate them.
        print("\n=== BEGIN REBUILT manifest.json ===\n\(json)\n=== END REBUILT manifest.json ===")

        // Also write to the simulator's sandbox /tmp so the engineer can
        // copy it out via xcrun simctl get_app_container.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebuilt-manifest-\(UUID().uuidString).json")
        try data.write(to: outURL)
        print("Also written to: \(outURL.path)")

        XCTAssertEqual(entries.count, 20,
                       "must detect BPM for all 20 bundled tracks (got \(entries.count))")
    }
}
