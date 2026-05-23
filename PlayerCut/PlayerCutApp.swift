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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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
    // captureController removed — PlayerCut no longer owns an
    // AVCaptureSession. The system Camera (UIImagePickerController)
    // owns capture; see CaptureView.

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
    @State private var presentingCompilation = false
    @State private var presentingAssistedTier = false
    @State private var presentingPaywall = false
    @AppStorage(OnboardingKeys.termsAccepted) private var termsAccepted = false
    @AppStorage(PermissionPrimerKeys.primerDone) private var permissionsPrimerDone = false
    @AppStorage(AssistedKeys.assistedTierShown) private var assistedTierShown = false
    @AppStorage(PricingKeys.freeReelsUsed) private var freeReelsUsedObserved = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()
                if coordinator.players.isEmpty {
                    emptyState
                } else {
                    populatedRoot
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptic.tap()
                        presentingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityIdentifier("settings-gear")
                }
            }
            .toolbarBackground(Theme.bgDark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $presentingEnrollment) {
                EnrollmentRootView(
                    vm: EnrollmentViewModel(store: coordinator.store),
                    onComplete: { _ in
                        presentingEnrollment = false
                        Task {
                            await coordinator.refresh()
                            // Surface the Assisted tier explainer once,
                            // right after the first successful enrollment.
                            if !assistedTierShown {
                                presentingAssistedTier = true
                            }
                        }
                    },
                    onCancel: { presentingEnrollment = false }
                )
            }
            .sheet(isPresented: $presentingAssistedTier) {
                NavigationStack {
                    AssistedTierView { presentingAssistedTier = false }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $presentingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $presentingCompilation) {
                if let player = coordinator.players.first {
                    CompilationView(player: player)
                        .environmentObject(coordinator)
                }
            }
            .fullScreenCover(isPresented: $presentingCapture) {
                if let player = coordinator.players.first {
                    CaptureView(player: player)
                        .environmentObject(coordinator)
                }
            }
            .fullScreenCover(isPresented: .constant(!termsAccepted)) {
                WelcomeView(onAccepted: { termsAccepted = true })
            }
            .fullScreenCover(isPresented: .constant(termsAccepted
                                                    && !permissionsPrimerDone)) {
                PermissionsPrimerView {
                    permissionsPrimerDone = true
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $presentingPaywall) {
                PaywallView(
                    onSubscribe: { _ in presentingPaywall = false },
                    onMaybeLater: { presentingPaywall = false }
                )
                .preferredColorScheme(.dark)
            }
            .onChange(of: freeReelsUsedObserved) { _, _ in
                if PricingGate.shouldShowPaywall {
                    presentingPaywall = true
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()
            heroBrand
            Text("No players yet.\nLet's get one on the roster.")
                .font(.pcHeading)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 40)
            Spacer()
            PCPillButton(title: "Enroll a player",
                         systemImage: "person.crop.circle.fill.badge.plus") {
                presentingEnrollment = true
            }
            .accessibilityIdentifier("enroll-player")
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Populated

    private var populatedRoot: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroBrand
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                    playerCards
                    gamesStrip
                }
                .padding(.bottom, 24)
            }
            ctaStack
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    private var heroBrand: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PlayerCut")
                .font(.pcHero)
                .foregroundStyle(Theme.textPrimary)
                .textCase(.uppercase)
                .tracking(2)
                .accessibilityIdentifier("hero-title")
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 72, height: 6)
        }
    }

    private var playerCards: some View {
        VStack(spacing: 12) {
            ForEach(coordinator.players, id: \.id) { player in
                playerCard(player)
            }
            Button {
                Haptic.tap()
                presentingEnrollment = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                    Text("ADD PLAYER")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(1.4)
                    Spacer()
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Theme.bgCard,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("add-player")
        }
        .padding(.horizontal, 20)
    }

    private func playerCard(_ player: PlayerEnrollment) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(player.name.uppercased())
                    .font(.pcTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(player.sport.rawValue.uppercased())
                    .font(.pcCaption)
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("#\(player.jerseyNumber)")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 20)
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .pcCard()
    }

    private var gamesStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent games".uppercased())
                .font(.pcCaption)
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
            if coordinator.games.isEmpty {
                Text("No games yet — tap RECORD to start.")
                    .font(.pcBody)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(coordinator.games, id: \.id) { game in
                            NavigationLink {
                                GameDetailView(gameID: game.id)
                                    .environmentObject(coordinator)
                            } label: {
                                gameCard(game)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func gameCard(_ game: GameSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Theme.primary.opacity(0.25)
                Image(systemName: game.status == .completed
                      ? "play.rectangle.fill" : "hourglass.circle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 200, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(game.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            PCStatusChip(title: statusLabel(game.status),
                         color: statusColor(game.status))
        }
        .padding(12)
        .frame(width: 224)
        .pcCard()
    }

    private func statusLabel(_ s: GameStatus) -> String {
        switch s {
        case .recording: return "REC"
        case .awaitingProcessing: return "QUEUED"
        case .stage1Running: return "STAGE 1"
        case .stage2Running: return "STAGE 2"
        case .composing: return "EXPORT"
        case .completed: return "READY"
        case .failed: return "FAILED"
        }
    }

    private func statusColor(_ s: GameStatus) -> Color {
        switch s {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .recording, .awaitingProcessing: return Theme.accent
        default: return Theme.primary
        }
    }

    private var ctaStack: some View {
        VStack(spacing: 12) {
            PCPillButton(title: "Record game",
                         systemImage: "record.circle.fill",
                         tint: Theme.primary,
                         height: 64) {
                presentingCapture = true
            }
            .accessibilityIdentifier("record-game")
            PCOutlinePillButton(title: "Compilation",
                                systemImage: "sparkles",
                                color: eligibleCompilationGames.count < 2
                                    ? Theme.textSecondary
                                    : Theme.accent,
                                height: 56) {
                presentingCompilation = true
            }
            .accessibilityIdentifier("compilation")
            .disabled(eligibleCompilationGames.count < 2)
            .opacity(eligibleCompilationGames.count < 2 ? 0.5 : 1.0)
        }
    }

    private var eligibleCompilationGames: [GameSession] {
        coordinator.games.filter { g in
            g.status == .completed
                && (g.exportedReelAssetId != nil
                    || g.localReelFallbackURL != nil)
        }
    }
}
