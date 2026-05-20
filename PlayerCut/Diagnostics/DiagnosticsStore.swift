//
//  DiagnosticsStore.swift
//  PlayerCut/Diagnostics
//
//  Local-only diagnostics. All counters and timing data live on-device. The
//  user can manually export a JSON of aggregates via the share sheet — no
//  network calls, no auto-upload, no SDK ingestion of any kind.
//
//  DESIGN RULES (these are non-negotiable for a kids-content app):
//
//   1. NEVER record names, jersey numbers, file paths, or anything that
//      could identify a child or game. Only EVENT NAMES and durations.
//
//   2. NEVER record absolute timestamps. Round to day-granularity for
//      retention metrics. Birthdays + game schedules can re-identify.
//
//   3. NEVER include image data or extracted features in any export.
//
//   4. The user opens diagnostics. The user explicitly taps "share." Then
//      and only then does data leave the device — and only via the system
//      share sheet, which lets the user choose where (email, AirDrop,
//      delete-on-paste).
//
//  What we DO record:
//   - Pipeline stage durations (Stage 1, Stage 2, total) — useful for
//     understanding device performance distributions.
//   - BG task submitted/handled/expired counters — the only honest measure
//     of whether iOS is granting time on real users' phones.
//   - Crash recovery counts (pipelines that resumed from a saved state).
//   - High-level outcome counters: reels_completed, reels_failed.
//

import Foundation
import os.log

actor DiagnosticsStore {

    static let shared = DiagnosticsStore()

    private let log = Logger(subsystem: "com.playercut.app", category: "Diag")
    private var snapshot: DiagnosticsSnapshot
    private let url: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("diagnostics.json")

        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(DiagnosticsSnapshot.self, from: data) {
            self.snapshot = loaded
        } else {
            self.snapshot = DiagnosticsSnapshot()
        }
    }

    // MARK: - Counters

    func increment(_ counter: CounterKey, by amount: Int = 1) {
        snapshot.counters[counter.rawValue, default: 0] += amount
        persistDebounced()
    }

    func recordDuration(_ key: DurationKey, seconds: Double) {
        var bucket = snapshot.durations[key.rawValue] ?? DurationBucket()
        bucket.add(seconds)
        snapshot.durations[key.rawValue] = bucket
        persistDebounced()
    }

    func recordEnum<T: RawRepresentable>(_ key: EnumKey, value: T)
        where T.RawValue == String {
        var dist = snapshot.enumDistributions[key.rawValue] ?? [:]
        dist[value.rawValue, default: 0] += 1
        snapshot.enumDistributions[key.rawValue] = dist
        persistDebounced()
    }

    /// Adds a "this happened today" sample. Only the day-bucketed count is
    /// kept; the absolute date is rounded to YYYY-MM-DD UTC and only the
    /// last 30 days are retained.
    func recordDailyEvent(_ key: DailyEventKey) {
        let day = dayKey(for: Date())
        var dist = snapshot.dailyEvents[key.rawValue] ?? [:]
        dist[day, default: 0] += 1
        snapshot.dailyEvents[key.rawValue] = dist
        prune(distribution: &snapshot.dailyEvents[key.rawValue]!,
              keep: 30)
        persistDebounced()
    }

    // MARK: - Read

    func currentSnapshot() -> DiagnosticsSnapshot {
        snapshot
    }

    // MARK: - Reset (user-initiated)

    func reset() {
        snapshot = DiagnosticsSnapshot()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private var pendingWrite: Task<Void, Never>?

    private func persistDebounced() {
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Diag persist failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func dayKey(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func prune(distribution: inout [String: Int], keep: Int) {
        guard distribution.count > keep else { return }
        let sortedKeys = distribution.keys.sorted()
        let drop = sortedKeys.prefix(distribution.count - keep)
        for k in drop { distribution.removeValue(forKey: k) }
    }
}

// MARK: - Snapshot data shapes

struct DiagnosticsSnapshot: Codable {
    var counters: [String: Int] = [:]
    var durations: [String: DurationBucket] = [:]
    var enumDistributions: [String: [String: Int]] = [:]
    var dailyEvents: [String: [String: Int]] = [:]
    var schemaVersion: Int = 1

    /// Pretty-printed JSON suitable for sharing via the system share sheet.
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct DurationBucket: Codable {
    var count: Int = 0
    var sum: Double = 0
    var min: Double = .infinity
    var max: Double = 0
    /// Approximate p50 (median) maintained via a small reservoir sample.
    /// Reservoir size is bounded so old values age out — this is fine for
    /// distributional understanding but is not a proper streaming median.
    var samples: [Double] = []

    mutating func add(_ value: Double) {
        count += 1
        sum += value
        if value < min { min = value }
        if value > max { max = value }
        if samples.count < 64 {
            samples.append(value)
        } else {
            samples[count % 64] = value
        }
    }

    var mean: Double { count == 0 ? 0 : sum / Double(count) }
    var p50: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Typed keys (the only event names allowed)

enum CounterKey: String {
    // Pipeline outcomes
    case reelsCompleted = "reels_completed"
    case reelsFailed = "reels_failed"
    case reelsRetriedFromResume = "reels_retried_from_resume"

    // Background tasks
    case bgTaskSubmitted = "bg_task_submitted"
    case bgTaskHandled = "bg_task_handled"
    case bgTaskExpired = "bg_task_expired"
    case foregroundFallbackCompleted = "fg_fallback_completed"

    // Capture
    case gamesRecorded = "games_recorded"
    case captureInterruptions = "capture_interruptions"

    // Identification
    case stage2NoIdentification = "stage2_no_identification"
    case stage2HighConfidenceIdentification = "stage2_high_conf_identification"

    // Mount-detection auto-start
    case autoStartTriggered = "auto_start_triggered"
    case autoStartFalsePositive = "auto_start_false_positive"

    // Zero-video-storage policy
    case rawVideoDeleted = "raw_video_deleted"
    case reelSavedToPhotos = "reel_saved_to_photos"
    case photoLibraryPermissionDenied = "photo_library_permission_denied"

    // Short / solo-practice recordings
    case shortReelProduced = "short_reel_produced"

    // Compilations
    case compilationsCreated = "compilations_created"

    // Never-reject ranker tiers
    case rankerTier1Used = "ranker_tier_1_used"
    case rankerTier2Used = "ranker_tier_2_used"
    case rankerTier3Used = "ranker_tier_3_used"
    /// Invariant check — should increment on every completed reel.
    /// Any divergence between this and reelsCompleted is a regression.
    case reelAlwaysProduced = "reel_always_produced"

    // Reel delivery (Section A)
    case reelSavedToPhotosRecents     = "reel_saved_to_photos_recents"
    case reelSavedToPlayerCutAlbum    = "reel_saved_to_playercut_album"
    case reelKeptLocalOnly            = "reel_kept_local_only"
    case reelPlayedFromLocal          = "reel_played_from_local"

    // Capture efficiency (Section B)
    case idleTimerDisabledDuringCapture = "idle_timer_disabled_during_capture"

    // Errors (categorized, never with text)
    case errorCaptureFailed = "err_capture_failed"
    case errorPipelineFailed = "err_pipeline_failed"
    case errorComposeFailed = "err_compose_failed"
}

enum DurationKey: String {
    case stage1 = "stage1_seconds"
    case stage2 = "stage2_seconds"
    case ranking = "ranking_seconds"
    case composition = "composition_seconds"
    case totalPipeline = "total_pipeline_seconds"
    case captureSession = "capture_session_seconds"
}

enum EnumKey: String {
    case sport = "sport"
    case deviceModel = "device_model"
    case iosMajorVersion = "ios_major_version"
    case reelLength = "reel_length"
    case sceneType = "scene_type"
    case photoAuthStatusAtSave = "photo_auth_status_at_save"
    case backgroundRefreshStatus = "background_refresh_status"
    case bluetoothAuthStatus = "bluetooth_auth_status"
    case notificationAuthStatus = "notification_auth_status"
}

enum DailyEventKey: String {
    case appOpened = "app_opened"
    case reelShared = "reel_shared"
    case enrollmentCompleted = "enrollment_completed"
}
