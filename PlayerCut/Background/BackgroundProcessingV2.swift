//
//  BackgroundProcessingV2.swift
//  PlayerCut
//
//  Production-quality background processing with the things v1 leaves out:
//
//   1. ADAPTIVE FALLBACK to foreground when iOS won't grant BG time. We've
//      all shipped apps where users thought "the reel is processing" but
//      iOS never actually scheduled the task. Solution: foreground processor
//      runs whenever the app is open AND a BG task hasn't completed yet.
//
//   2. PARTIAL-PROGRESS RESUME. The orchestrator persists Stage1Result the
//      moment it's done; if iOS reclaims the task during Stage 2, the next
//      run starts at Stage 2 with the cached candidates. Critical for 90-min
//      games on older phones.
//
//   3. EXPIRATION GRACE. iOS gives you ~3 seconds after expirationHandler
//      fires before it kills the process. We use that window to flush state.
//
//   4. DIAGNOSTIC INSTRUMENTATION. Every state transition is logged with
//      OSLog so you can use Console.app to see what iOS actually did with
//      your task requests. This is the ONLY way to debug.
//

import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import os.log

@MainActor
final class BackgroundProcessingV2 {

    static let shared = BackgroundProcessingV2()

    // MUST match Info.plist BGTaskSchedulerPermittedIdentifiers
    static let processingIdentifier = "com.playercut.app.process-game"
    static let appRefreshIdentifier = "com.playercut.app.refresh"

    private let log = Logger(subsystem: "com.playercut.app", category: "BG")
    private let signposter = OSSignposter(subsystem: "com.playercut.app",
                                          category: "BG-perf")

    private weak var orchestrator: PipelineOrchestrator?
    private var queue: [UUID] = []

    // Tracks the currently-running pipeline so we can react to expiration
    // and so we never start two pipelines for the same game.
    private var activeGameID: UUID?
    private var activePipelineTask: Task<Void, Never>?

    // Used for the foreground-fallback runner.
    private var foregroundRunner: Task<Void, Never>?

    // MARK: - Registration

    func register(orchestrator: PipelineOrchestrator) {
        self.orchestrator = orchestrator

        // Register both task types. Processing tasks can be long-running but
        // are stingily granted by iOS. App refresh runs more often but is
        // capped at 30 seconds — useful as a "ping" to re-submit a processing
        // request if the previous one was deferred.
        let registered1 = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self.handleProcessingTask(processingTask)
            }
        }

        let registered2 = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.appRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self.handleRefreshTask(refreshTask)
            }
        }

        log.info("BG registration: processing=\(registered1), refresh=\(registered2)")

        loadQueue()

        // Hook app lifecycle: when the app is foregrounded with pending work,
        // start the foreground runner so users don't sit waiting on iOS.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startForegroundRunnerIfNeeded()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopForegroundRunner()
                self?.scheduleAllPendingTasks()
            }
        }
    }

    // MARK: - Public API

    func enqueueGame(_ id: UUID) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        saveQueue()
        log.info("Enqueued \(id.uuidString); queue size now \(self.queue.count)")

        // Try BG first, but kick off foreground runner if app is active.
        scheduleAllPendingTasks()
        if UIApplication.shared.applicationState == .active {
            startForegroundRunnerIfNeeded()
        }
    }

    // MARK: - Scheduling strategy

    private func scheduleAllPendingTasks() {
        guard !queue.isEmpty else { return }

        // Submit a processing task (allowed to run when on charger, possibly
        // for many minutes).
        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        // Also submit an app-refresh task as a fallback "ping" — refresh
        // tasks run more often, so even if iOS keeps deferring the
        // processing task, we get a periodic chance to re-evaluate.
        let refresh = BGAppRefreshTaskRequest(identifier: Self.appRefreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            // Note: cancelling first is required if we already have a
            // pending request — iOS allows only one of each identifier.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.appRefreshIdentifier)

            try BGTaskScheduler.shared.submit(processing)
            try BGTaskScheduler.shared.submit(refresh)
            log.info("Submitted BG processing + refresh requests")
        } catch BGTaskScheduler.Error.unavailable {
            log.error("BG tasks unavailable on this device")
        } catch BGTaskScheduler.Error.tooManyPendingTaskRequests {
            log.error("Too many pending BG tasks")
        } catch {
            log.error("BG submit error: \(error.localizedDescription)")
        }
    }

    // MARK: - Task handlers

    private func handleProcessingTask(_ task: BGProcessingTask) async {
        let interval = signposter.beginInterval("BGProcessing",
                                                "queueSize=\(self.queue.count)")
        defer { signposter.endInterval("BGProcessing", interval) }

        log.info("BGProcessingTask invoked; queue size \(self.queue.count)")

        guard let gameID = queue.first else {
            task.setTaskCompleted(success: true)
            return
        }

        // Set up an expiration handler BEFORE starting work. iOS gives ~3s
        // grace after this fires; we use it to flush state and bail.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.log.warning("BG task expiring; cancelling pipeline")
                self.activePipelineTask?.cancel()
                // The orchestrator's per-stage persistence ensures partial
                // progress is on disk by the time this returns.
                task.setTaskCompleted(success: false)
            }
        }

        // Run the pipeline. If iOS lets us complete, great. If it expires,
        // the next BG run (or foreground runner) picks up where we stopped.
        let success = await runPipeline(for: gameID)

        if success {
            queue.removeAll { $0 == gameID }
            saveQueue()
        }
        task.setTaskCompleted(success: success)

        // Re-submit so the next queued game gets a slot.
        if !queue.isEmpty {
            scheduleAllPendingTasks()
        }
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) async {
        log.info("BG refresh task invoked")
        // Refresh tasks have only ~30s. Don't try to run the pipeline here.
        // Just resubmit the processing request and update notifications.
        scheduleAllPendingTasks()
        task.setTaskCompleted(success: true)
    }

    // MARK: - Pipeline runner

    private func runPipeline(for gameID: UUID) async -> Bool {
        guard let orchestrator else { return false }
        guard activeGameID != gameID else {
            log.info("Pipeline already running for \(gameID.uuidString); skipping")
            return false
        }
        activeGameID = gameID

        var success = false
        let runner = Task {
            for await progress in await orchestrator.run(gameId: gameID,
                                                         musicURL: nil) {
                switch progress {
                case .completed(let url):
                    self.log.info("Pipeline completed for \(gameID.uuidString)")
                    success = true
                    self.notifyReelReady(gameID: gameID, reelURL: url)
                case .failed(let error):
                    self.log.error("Pipeline failed: \(error.localizedDescription)")
                    self.notifyReelFailed(gameID: gameID)
                default:
                    break
                }
                if Task.isCancelled { break }
            }
        }
        activePipelineTask = runner
        await runner.value
        activePipelineTask = nil
        activeGameID = nil
        return success
    }

    // MARK: - Foreground fallback

    /// Kicks off the pipeline in the foreground whenever the app is active
    /// and there is queued work that BG hasn't picked up yet. This is the
    /// safety net for "iOS just refused to schedule us today."
    private func startForegroundRunnerIfNeeded() {
        guard foregroundRunner == nil else { return }
        guard !queue.isEmpty else { return }

        log.info("Starting foreground runner for \(self.queue.count) queued games")

        foregroundRunner = Task { @MainActor in
            // Keep the system from sleeping. UIApplication.isIdleTimerDisabled
            // only works while in foreground but is exactly what we need here.
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }

            while !Task.isCancelled, let next = queue.first {
                let success = await runPipeline(for: next)
                if success {
                    queue.removeAll { $0 == next }
                    saveQueue()
                } else {
                    // If we failed in foreground, don't loop forever — let
                    // the user retry manually or wait for next BG window.
                    break
                }
            }
            foregroundRunner = nil
        }
    }

    private func stopForegroundRunner() {
        foregroundRunner?.cancel()
        foregroundRunner = nil
    }

    // MARK: - Notifications

    private func notifyReelReady(gameID: UUID, reelURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Highlight reel ready"
        content.body = "Tap to watch and share."
        content.sound = .default
        content.categoryIdentifier = "REEL_READY"
        content.userInfo = ["gameId": gameID.uuidString,
                            "reelURL": reelURL.absoluteString]

        let req = UNNotificationRequest(identifier: "reel-\(gameID.uuidString)",
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                self.log.error("Notify failed: \(error.localizedDescription)")
            }
        }
    }

    private func notifyReelFailed(gameID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't make your reel"
        content.body = "Open PlayerCut to retry."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "reel-fail-\(gameID.uuidString)",
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Queue persistence

    private func saveQueue() {
        let data = try? JSONEncoder().encode(queue)
        try? data?.write(to: StoragePaths.queueURL, options: .atomic)
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: StoragePaths.queueURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return
        }
        queue = ids
        log.info("Loaded persisted queue with \(self.queue.count) games")
    }
}

// MARK: - Debugging

#if DEBUG
extension BackgroundProcessingV2 {
    /// Force a simulated BG task fire from the debugger.
    ///
    /// Pause execution in Xcode and run:
    ///
    ///   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.playercut.app.process-game"]
    ///
    /// Or, equivalently, programmatically:
    func debugSimulateLaunch() {
        let selectorName = "_simulateLaunchForTaskWithIdentifier:"
        let selector = NSSelectorFromString(selectorName)
        if BGTaskScheduler.shared.responds(to: selector) {
            _ = BGTaskScheduler.shared.perform(selector,
                                               with: Self.processingIdentifier)
        }
    }

    /// Print all currently-pending task requests to OSLog. Useful for
    /// confirming your earliestBeginDate is reasonable and that you don't
    /// have orphaned requests piling up.
    func debugDumpPendingRequests() async {
        let requests = await BGTaskScheduler.shared.pendingTaskRequests()
        for r in requests {
            log.info("Pending: \(r.identifier) earliestBegin=\(r.earliestBeginDate?.description ?? "nil")")
        }
    }
}
#endif
