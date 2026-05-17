//
//  BackgroundProcessing.swift
//  PlayerCut
//
//  Schedules and handles the post-game pipeline as a BGProcessingTask so it
//  runs while the phone is idle and on charger. iOS gives us up to a few minutes
//  of foreground time when the user taps "Stop", which is not enough for a
//  90-min game; the heavy lifting must happen in the background.
//
//  Info.plist requires:
//    UIBackgroundModes = ["processing"]
//    BGTaskSchedulerPermittedIdentifiers = ["com.playercut.app.process-game"]
//

import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import os.log

final class BackgroundProcessing {

    static let shared = BackgroundProcessing()
    static let taskIdentifier = "com.playercut.app.process-game"

    private let log = Logger(subsystem: "com.playercut.app", category: "Background")
    private weak var orchestrator: PipelineOrchestrator?
    private var pendingGameIDs: [UUID] = []

    func register(orchestrator: PipelineOrchestrator) {
        self.orchestrator = orchestrator

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self,
                  let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProcessingTask(processingTask)
        }
        log.info("BG task registered")
    }

    /// Called immediately after recording stops. Queues this specific game
    /// and submits a BGProcessingTaskRequest.
    func enqueueGame(_ id: UUID) {
        if !pendingGameIDs.contains(id) {
            pendingGameIDs.append(id)
            persistQueue()
        }
        scheduleNextRun()
    }

    func loadPersistedQueue() {
        let url = StoragePaths.queueURL
        if let data = try? Data(contentsOf: url),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            pendingGameIDs = ids
        }
    }

    // MARK: - Scheduling

    private func scheduleNextRun() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // give user 1 min

        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("BG task submitted")
        } catch {
            log.error("BG submit failed: \(error.localizedDescription)")
            // Fall back to immediate foreground processing if user keeps app open
        }
    }

    // MARK: - Handling

    private func handleProcessingTask(_ task: BGProcessingTask) {
        guard let orchestrator else {
            task.setTaskCompleted(success: false)
            return
        }

        // Pop the next pending game
        guard let gameId = pendingGameIDs.first else {
            task.setTaskCompleted(success: true)
            return
        }

        let processingTask = Task {
            var success = false
            for await progress in await orchestrator.run(gameId: gameId,
                                                         musicURL: defaultMusicURL()) {
                switch progress {
                case .completed(let url):
                    success = true
                    notifyUser(forGame: gameId, reelURL: url)
                case .failed(let error):
                    notifyUserOfFailure(gameId: gameId, error: error)
                default:
                    break
                }
            }
            if success {
                pendingGameIDs.removeAll { $0 == gameId }
                persistQueue()
            }
            task.setTaskCompleted(success: success)

            // If there are more games queued, schedule another run
            if !pendingGameIDs.isEmpty {
                scheduleNextRun()
            }
        }

        task.expirationHandler = {
            // iOS is reclaiming the task. Cancel cleanly; we'll resume next time
            // because the partial state was persisted by the orchestrator.
            processingTask.cancel()
        }
    }

    // MARK: - User notifications

    private func notifyUser(forGame id: UUID, reelURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Your highlight reel is ready"
        content.body = "Tap to watch and share."
        content.sound = .default
        content.userInfo = ["gameId": id.uuidString,
                            "reelURL": reelURL.absoluteString]

        let request = UNNotificationRequest(identifier: "reel-\(id)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyUserOfFailure(gameId: UUID, error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "We couldn't make your reel"
        content.body = "Open the app to try again."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "reel-fail-\(gameId)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func persistQueue() {
        let url = StoragePaths.queueURL
        if let data = try? JSONEncoder().encode(pendingGameIDs) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func defaultMusicURL() -> URL? {
        Bundle.main.url(forResource: "default_bed", withExtension: "m4a")
    }
}
