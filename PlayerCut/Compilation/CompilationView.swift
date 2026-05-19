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
            ZStack {
                Theme.bgDark.ignoresSafeArea()
                VStack(spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            sectionHeader("Length")
                            Picker("Length", selection: $length) {
                                ForEach(CompilationLength.allCases, id: \.self) { l in
                                    Text(l.displayName).tag(l)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("Each selected game gets an equal share of the final reel.")
                                .font(.pcCaption)
                                .foregroundStyle(Theme.textSecondary)

                            sectionHeader("Games for \(player.name.uppercased())")
                            if eligibleGames.isEmpty {
                                Text("NO COMPLETED GAMES YET")
                                    .font(.pcCaption)
                                    .tracking(1.4)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.vertical, 30)
                                    .frame(maxWidth: .infinity)
                                    .background(Theme.bgCard,
                                                in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                            } else {
                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)
                                ], spacing: 12) {
                                    ForEach(eligibleGames, id: \.id) { game in
                                        gameTile(game)
                                    }
                                }
                            }

                            if let statusMessage {
                                Text(statusMessage)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(20)
                    }

                    PCPillButton(title: building ? "Building…" : "Build compilation",
                                 systemImage: building ? nil : "sparkles",
                                 tint: selectedGameIDs.count < 2
                                    ? Theme.textSecondary
                                    : Theme.accent,
                                 height: 64) {
                        build()
                    }
                    .disabled(selectedGameIDs.count < 2 || building)
                    .opacity(selectedGameIDs.count < 2 || building ? 0.6 : 1)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("COMPILATION")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgDark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("CANCEL") { dismiss() }
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.pcCaption)
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
    }

    private func gameTile(_ game: GameSession) -> some View {
        let selected = selectedGameIDs.contains(game.id)
        return Button {
            Haptic.tap()
            toggle(game.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Theme.primary.opacity(0.25)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Image(systemName: selected
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        .padding(8)
                }
                Text(game.startedAt.formatted(
                    date: .abbreviated, time: .shortened))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(game.sport.rawValue.uppercased())
                    .font(.pcCaption)
                    .tracking(1.4)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(selected
                        ? Theme.bgCard.opacity(1)
                        : Theme.bgCard.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2)
            )
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
