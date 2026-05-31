//
//  MusicImport.swift
//  PlayerCut/Music
//
//  Bring-your-own-music import path. Users tap "Add your own track" in
//  Settings → Music; UIDocumentPicker (`.audio`) returns a file URL; we
//  copy it to the app sandbox (`Application Support/ImportedMusic/`),
//  run BPMDetector to get a real tempo, derive a best-guess MusicVibe
//  from the envelope shape, and persist a small JSON manifest so the
//  next launch sees the same library.
//
//  No network. No third-party SDKs. The imported file never leaves the
//  device; we only copy it into our sandbox so the music picker doesn't
//  hold onto the source's security-scoped URL.
//

import AVFoundation
import Foundation
import os.log

/// Stored metadata for one user-imported track. The on-disk URL is
/// resolved relative to the ImportedMusic/ sandbox folder at read
/// time so backup/restore + bundle-id changes don't break links.
struct ImportedTrack: Codable, Identifiable, Equatable {

    /// Persistent uuid-derived id: "imported_<uuid>". Used by
    /// MusicLibrary as the Track id.
    let id: String

    /// User-visible name (from the original filename, sans extension).
    var displayName: String

    /// Filename inside ImportedMusic/. URL is rebuilt from the sandbox
    /// path each read so we don't store an absolute path.
    let fileName: String

    /// Detected BPM. nil = detection ran but fell back / unknown; the
    /// editor uses 120 as a final fallback.
    var bpm: Int?

    /// Vibe — auto-inferred from the RMS envelope's variance + dominant
    /// tempo, user can override later via Settings.
    var vibe: MusicVibe

    /// Asset duration in seconds.
    var duration: Double

    /// Wall-clock import time. Stable sort key in the Settings list.
    var importedAt: Date
}

@MainActor
final class MusicImportManager {

    static let shared = MusicImportManager()

    private let logger = Logger(subsystem: "com.playercut.app",
                                category: "MusicImport")

    /// Application Support/ImportedMusic/. Created on first import.
    private(set) lazy var importDirectory: URL = {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = (appSupport ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ImportedMusic", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var manifestURL: URL {
        importDirectory.appendingPathComponent("manifest.json")
    }

    /// In-memory cache of the on-disk manifest. Mutate via `add` / `remove`
    /// then `persist`; read by MusicLibrary at compose / list time.
    private(set) var tracks: [ImportedTrack] = []

    private init() {
        self.tracks = loadManifest()
    }

    // MARK: - Public API

    /// User picked `sourceURL` from UIDocumentPicker. We copy it into
    /// the sandbox, run BPMDetector, infer the vibe, append to the
    /// manifest. Returns the new track on success.
    ///
    /// The caller is responsible for stopping any security-scoped
    /// access on `sourceURL` after this call returns.
    func importTrack(from sourceURL: URL) async throws -> ImportedTrack {
        let ext = sourceURL.pathExtension.lowercased()
        let supportedExt: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "caf"]
        guard supportedExt.contains(ext) else {
            throw ImportError.unsupportedFormat(ext)
        }

        let uuid = UUID().uuidString
        let id = "imported_\(uuid)"
        let dstName = "\(id).\(ext)"
        let dstURL = importDirectory.appendingPathComponent(dstName)

        // Copy the file into our sandbox so the picker's security-scoped
        // URL doesn't get torn out from under us. iCloud Drive sources
        // may need `startAccessingSecurityScopedResource`; the picker
        // wrapper handles that.
        try FileManager.default.copyItem(at: sourceURL, to: dstURL)

        // Probe duration before BPM so we can short-circuit silly inputs.
        let asset = AVURLAsset(url: dstURL)
        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            try? FileManager.default.removeItem(at: dstURL)
            throw ImportError.unreadable(error.localizedDescription)
        }
        guard duration > 5 else {
            try? FileManager.default.removeItem(at: dstURL)
            throw ImportError.tooShort(duration)
        }

        // BPM + vibe inference.
        let bpmResult = await BPMDetector.detect(url: dstURL)
        let inferredVibe = await inferVibe(url: dstURL, bpm: bpmResult.bpm)

        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let track = ImportedTrack(
            id: id,
            displayName: displayName,
            fileName: dstName,
            bpm: bpmResult.didFallback ? nil : Int(bpmResult.bpm.rounded()),
            vibe: inferredVibe,
            duration: duration,
            importedAt: Date())
        tracks.append(track)
        persist()
        logger.info("Imported '\(displayName, privacy: .public)' as \(track.id, privacy: .public) bpm=\(track.bpm ?? 0) vibe=\(inferredVibe.rawValue, privacy: .public) duration=\(duration, format: .fixed(precision: 1))s")
        return track
    }

    /// Updates the user-editable fields on an imported track. Persists
    /// on success.
    func update(id: String,
                displayName: String? = nil,
                vibe: MusicVibe? = nil) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        if let displayName { tracks[idx].displayName = displayName }
        if let vibe        { tracks[idx].vibe = vibe }
        persist()
    }

    /// Deletes both the on-disk file and the manifest entry.
    func remove(id: String) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        let track = tracks[idx]
        try? FileManager.default.removeItem(
            at: importDirectory.appendingPathComponent(track.fileName))
        tracks.remove(at: idx)
        persist()
        logger.info("Removed imported track \(id, privacy: .public)")
    }

    /// URL inside the sandbox for the given imported track id. nil
    /// when the file was deleted out-of-band.
    func url(for id: String) -> URL? {
        guard let entry = tracks.first(where: { $0.id == id }) else { return nil }
        let url = importDirectory.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Vibe inference

    /// Cheap heuristic: BPM × envelope variance bands. > 130 BPM with
    /// high RMS variance reads as energetic; < 95 BPM with low variance
    /// reads as chill; the rest split between playful and cinematic.
    /// User can override in Settings.
    private func inferVibe(url: URL, bpm: Double) async -> MusicVibe {
        let variance = await rmsVariance(url: url)
        // Variance is dimensionless because the envelope is normalized;
        // empirical thresholds from the 20 Pixabay bundled tracks land
        // chill < 0.04 < playful/cinematic < 0.10 < energetic.
        switch (bpm, variance) {
        case (130..., 0.08...):   return .energetic
        case (..<95,  ..<0.05):   return .chill
        case (95...130, ..<0.06): return .cinematic
        default:                  return .playful
        }
    }

    /// RMS-envelope variance, normalized by the envelope mean so the
    /// scale matches across input gain levels. Hop = 100 Hz to share
    /// the BPMDetector's decode pattern.
    private func rmsVariance(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return 0
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }

        var envelope: [Double] = []
        let hopFrames = 160  // 10 ms hop at 16 kHz
        var carry: [Int16] = []
        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let raw = ptr, length >= 2 else { continue }
            let n = length / 2
            let chunk = raw.withMemoryRebound(to: Int16.self, capacity: n) { p in
                Array(UnsafeBufferPointer(start: p, count: n))
            }
            carry.append(contentsOf: chunk)
            var i = 0
            while i + hopFrames <= carry.count {
                var sumSq: Double = 0
                for j in i..<(i + hopFrames) {
                    let v = Double(carry[j])
                    sumSq += v * v
                }
                envelope.append((sumSq / Double(hopFrames)).squareRoot())
                i += hopFrames
            }
            if i > 0 { carry.removeFirst(i) }
        }
        guard envelope.count > 100 else { return 0 }
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        guard mean > 1e-9 else { return 0 }
        let variance = envelope.reduce(0) { acc, v in
            acc + pow(v - mean, 2)
        } / Double(envelope.count)
        return variance.squareRoot() / mean   // CV = σ/μ, scale-free
    }

    // MARK: - Persistence

    private func loadManifest() -> [ImportedTrack] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        do {
            return try JSONDecoder().decode([ImportedTrack].self, from: data)
        } catch {
            logger.warning("ImportedMusic manifest decode failed: \(error.localizedDescription, privacy: .public) — starting empty")
            return []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            logger.error("ImportedMusic manifest write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case unreadable(String)
        case tooShort(Double)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "That file type (.\(ext)) isn't a supported audio format. Try .mp3 or .m4a."
            case .unreadable(let reason):
                return "Couldn't read that audio file: \(reason)"
            case .tooShort(let seconds):
                return "That track is only \(String(format: "%.1f", seconds))s long. Pick something at least 5 s."
            }
        }
    }
}
