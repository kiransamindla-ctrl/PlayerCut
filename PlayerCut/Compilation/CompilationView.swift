//
//  CompilationView.swift
//  PlayerCut/Compilation
//
//  Multi-select past games for the given player; choose a target
//  length; stitch the selected games' reels into one end-of-season
//  compilation via CompilationOrchestrator.
//

import SwiftUI

struct CompilationView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let player: PlayerEnrollment

    @State private var selectedGameIDs: Set<UUID> = []
    @State private var length: CompilationLength = .twoMinutes
    @State private var building = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Length", selection: $length) {
                        ForEach(CompilationLength.allCases, id: \.self) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Compilation length")
                } footer: {
                    Text("Each selected game gets an equal share of the final reel.")
                }

                Section {
                    if eligibleGames.isEmpty {
                        Text("No completed games yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleGames, id: \.id) { game in
                            gameRow(game)
                        }
                    }
                } header: {
                    Text("Games for \(player.name)")
                } footer: {
                    Text("Select 2 or more to build a compilation.")
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Compilation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        build()
                    } label: {
                        if building {
                            ProgressView()
                        } else {
                            Text("Build").bold()
                        }
                    }
                    .disabled(selectedGameIDs.count < 2 || building)
                }
            }
        }
    }

    // MARK: - Subviews

    private func gameRow(_ game: GameSession) -> some View {
        Button {
            toggle(game.id)
        } label: {
            HStack {
                Image(systemName: selectedGameIDs.contains(game.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(selectedGameIDs.contains(game.id)
                                     ? Color.accentColor
                                     : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.startedAt.formatted(
                        date: .abbreviated, time: .shortened))
                        .font(.body)
                    Text(game.sport.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private var eligibleGames: [GameSession] {
        coordinator.games.filter { g in
            g.playerId == player.id
                && g.status == .completed
                && (g.exportedReelAssetId != nil
                    || g.localReelFallbackURL != nil)
        }
    }

    private func toggle(_ id: UUID) {
        if selectedGameIDs.contains(id) {
            selectedGameIDs.remove(id)
        } else {
            selectedGameIDs.insert(id)
        }
    }

    // MARK: - Actions

    private func build() {
        guard !building else { return }
        building = true
        statusMessage = "Building compilation…"
        Task {
            do {
                let result = try await CompilationOrchestrator.compose(
                    gameIDs: Array(selectedGameIDs),
                    store: coordinator.store,
                    length: length)
                if result.savedToPhotos {
                    statusMessage = "Saved to PlayerCut Compilations album"
                } else {
                    statusMessage = "Saved locally — grant Photos access to upload"
                }
                building = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
                building = false
            }
        }
    }
}
