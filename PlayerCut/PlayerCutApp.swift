//
//  PlayerCutApp.swift
//  PlayerCut
//
//  Top-level app entry. Wires GameStore, PipelineOrchestrator, and
//  BackgroundProcessingV2 on launch.
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
    let captureController = GameCaptureController()

    @Published var games: [GameSession] = []
    @Published var players: [PlayerEnrollment] = []

    func bootstrap() async {
        BackgroundProcessingV2.shared.register(orchestrator: orchestrator)

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
        BackgroundProcessingV2.shared.enqueueGame(game.id)
        await refresh()
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var presentingEnrollment = false
    @State private var presentingCapture = false
    @State private var presentingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.players.isEmpty {
                    emptyState
                } else {
                    populatedList
                }
            }
            .navigationTitle("PlayerCut")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
                if !coordinator.players.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentingCapture = true
                        } label: {
                            Label("Record game", systemImage: "record.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $presentingEnrollment) {
                EnrollmentRootView(
                    vm: EnrollmentViewModel(store: coordinator.store),
                    onComplete: { _ in
                        presentingEnrollment = false
                        Task { await coordinator.refresh() }
                    },
                    onCancel: { presentingEnrollment = false }
                )
            }
            .sheet(isPresented: $presentingSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $presentingCapture) {
                if let player = coordinator.players.first {
                    CaptureView(player: player)
                        .environmentObject(coordinator)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("No players yet")
                .font(.title2)
            Button {
                presentingEnrollment = true
            } label: {
                Text("Enroll a player")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var populatedList: some View {
        List {
            Section("Players") {
                ForEach(coordinator.players, id: \.id) { player in
                    HStack {
                        Text(player.name).font(.body)
                        Spacer()
                        Text("#\(player.jerseyNumber)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    presentingEnrollment = true
                } label: {
                    Label("Add another player", systemImage: "plus")
                }
            }

            Section("Games") {
                if coordinator.games.isEmpty {
                    Text("No games yet — tap Record to start.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.games, id: \.id) { game in
                        NavigationLink {
                            GameDetailView(gameID: game.id)
                                .environmentObject(coordinator)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.startedAt.formatted(
                                    date: .abbreviated, time: .shortened))
                                Text(game.status.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
