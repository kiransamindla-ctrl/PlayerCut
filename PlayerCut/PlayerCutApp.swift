//
//  PlayerCutApp.swift
//  PlayerCut
//
//  Top-level app entry. Wires GameStore, PipelineOrchestrator, and
//  BackgroundProcessing on launch.
//

import SwiftUI
import UserNotifications

@main
struct PlayerCutApp: App {

    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .task {
                    await coordinator.bootstrap()
                }
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    let store = GameStore()
    lazy var orchestrator = PipelineOrchestrator(store: store)

    @Published var games: [GameSession] = []
    @Published var players: [PlayerEnrollment] = []

    func bootstrap() async {
        BackgroundProcessing.shared.register(orchestrator: orchestrator)
        BackgroundProcessing.shared.loadPersistedQueue()

        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])

        await refresh()
    }

    func refresh() async {
        games = await store.allGames()
        players = await store.allPlayers()
    }

    /// Called from the UI when the user taps "Stop game".
    func didFinishRecording(game: GameSession) async {
        try? await store.upsert(game)
        BackgroundProcessing.shared.enqueueGame(game.id)
        await refresh()
    }
}

struct RootView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    var body: some View {
        // Stub UI — production would show enrollment, capture, history
        NavigationStack {
            List(coordinator.games, id: \.id) { game in
                VStack(alignment: .leading) {
                    Text(game.startedAt.formatted())
                    Text(game.status.rawValue).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PlayerCut")
        }
    }
}
