//
//  GameDetailView.swift
//  PlayerCut/Pipeline
//
//  Plays the canonical local reel from Documents/reels/<id>.mp4 and
//  shares it via UIActivityViewController. Never reaches into Photos /
//  PHAsset for playback — under "Add Photos Only" we cannot read the
//  library, and there's no need to: the sandbox file is the source of
//  truth.
//
//  Crash-proof state machine:
//   - localReelURL present + file exists  → play it
//   - pipeline still running               → status + StadiumLightBar
//   - pipeline done but no local reel      → "Re-process" CTA, never crash
//

import AVKit
import SwiftUI

struct GameDetailView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    let gameID: UUID

    @State private var game: GameSession?
    @State private var refreshTimer = Timer.publish(every: 2,
                                                    on: .main,
                                                    in: .common).autoconnect()
    @State private var presentingShare = false
    @State private var manualRun: Task<Void, Never>?
    @State private var manualRunLog: String?

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            if let game {
                content(for: game)
            } else {
                ProgressView("Loading…")
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bgDark, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await reload() }
        .onReceive(refreshTimer) { _ in Task { await reload() } }
    }

    @ViewBuilder
    private func content(for game: GameSession) -> some View {
        if game.status == .completed {
            completedContent(for: game)
        } else {
            processingContent(for: game)
        }
    }

    // MARK: - Completed state

    @ViewBuilder
    private func completedContent(for game: GameSession) -> some View {
        // The canonical playback source is the local sandbox file —
        // never PHAsset. Belt-and-braces: also require the file to
        // exist on disk before we hand it to AVPlayer.
        if let local = playableLocalURL(for: game) {
            VStack(spacing: 0) {
                VideoPlayer(player: AVPlayer(url: local))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onAppear {
                        Task { await DiagnosticsStore.shared.increment(.reelPlayedFromLocal) }
                    }

                VStack(spacing: 8) {
                    savedLocationLine(for: game)
                    HStack(spacing: 12) {
                        PCPillButton(title: "Share",
                                     systemImage: "square.and.arrow.up.fill",
                                     tint: Theme.accent,
                                     height: 60) {
                            presentingShare = true
                        }
                        Button {
                            Haptic.warning()
                            // Local-file deletion isn't wired yet; the
                            // user can delete from Photos directly.
                            // TODO Delete-LAUNCH: also remove the
                            // sandbox copy + game record on confirm.
                        } label: {
                            Text("DELETE")
                                .font(.system(size: 14, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 18)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
                .background(Theme.bgDark)
            }
            .sheet(isPresented: $presentingShare) {
                LocalFileShareSheet(url: local)
            }
        } else {
            missingReelFallback(for: game)
        }
    }

    /// Banner under the player that tells the user exactly where the
    /// reel ended up. Three states per the spec.
    private func savedLocationLine(for game: GameSession) -> some View {
        let text: String
        let icon: String
        let color: Color
        if game.savedToPhotos, game.exportedReelAssetId != nil {
            text = "Saved to Photos → PlayerCut album"
            icon = "photo.stack.fill"
            color = Theme.success
        } else if game.savedToPhotos {
            text = "Saved to your Photos (Recents)"
            icon = "photo.fill"
            color = Theme.success
        } else {
            text = "Saved in PlayerCut — tap to allow Photos and save a copy"
            icon = "exclamationmark.triangle.fill"
            color = Theme.accent
        }
        return Button {
            if !game.savedToPhotos {
                openSystemSettings()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(text)
                    .font(.pcCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bgCard,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .disabled(game.savedToPhotos)
    }

    private func missingReelFallback(for game: GameSession) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("REEL MISSING")
                .font(.pcHeading)
                .tracking(1.3)
                .foregroundStyle(Theme.textPrimary)
            Text("The reel file isn't on this device — re-process to make a new one.")
                .font(.pcCaption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            PCPillButton(title: "Re-process",
                         systemImage: "arrow.clockwise.circle.fill",
                         tint: Theme.accent,
                         height: 56) {
                runNow(gameID: game.id)
            }
            .padding(.horizontal, 30)
            if let manualRunLog {
                Text(manualRunLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    /// Returns the playable URL only when both the field is set AND
    /// the file is actually on disk. Guards against orphaned game
    /// records (e.g. sandbox wiped via Settings → iPhone Storage).
    private func playableLocalURL(for game: GameSession) -> URL? {
        guard let url = game.localReelURL else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Processing state

    @ViewBuilder
    private func processingContent(for game: GameSession) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text(statusLabel(game.status))
                .font(.pcTitle)
                .foregroundStyle(Theme.textPrimary)
                .tracking(1)
            StadiumLightBar(stage: stageIndex(game.status))
                .frame(height: 28)
            Text("Started \(game.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.pcCaption)
                .foregroundStyle(Theme.textSecondary)

            if game.status == .awaitingProcessing || game.status == .failed {
                PCPillButton(title: manualRun == nil ? "Process Now" : "Processing…",
                             systemImage: "play.fill",
                             tint: Theme.accent,
                             height: 64) {
                    runNow(gameID: game.id)
                }
                .disabled(manualRun != nil)
                .opacity(manualRun == nil ? 1 : 0.5)
            }

            if let manualRunLog {
                Text(manualRunLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(20)
    }

    /// Maps a GameStatus to a 0-based stage index for the progress bar.
    private func stageIndex(_ s: GameStatus) -> Int {
        switch s {
        case .recording, .awaitingProcessing: return 0
        case .stage1Running: return 1
        case .stage2Running: return 2
        case .composing: return 3
        case .completed: return 4
        case .failed: return -1
        }
    }

    // MARK: - Helpers

    private func statusLabel(_ status: GameStatus) -> String {
        switch status {
        case .recording: return "RECORDING…"
        case .awaitingProcessing: return "WAITING TO PROCESS"
        case .stage1Running: return "STAGE 1 — COARSE DETECTION"
        case .stage2Running: return "STAGE 2 — PLAYER ID"
        case .composing: return "COMPOSING REEL"
        case .completed: return "READY"
        case .failed: return "FAILED"
        }
    }

    private func reload() async {
        await coordinator.refresh()
        game = coordinator.games.first { $0.id == gameID }
    }

    private func runNow(gameID: UUID) {
        guard manualRun == nil else { return }
        manualRunLog = "Starting…"
        manualRun = Task {
            let stream = await coordinator.orchestrator.run(gameId: gameID,
                                                            musicURL: nil)
            for await progress in stream {
                manualRunLog = describe(progress)
                if case .completed = progress { break }
                if case .failed = progress { break }
            }
            await coordinator.refresh()
            manualRun = nil
        }
    }

    private func describe(_ p: PipelineOrchestrator.Progress) -> String {
        switch p {
        case .stage1Started: return "Stage 1 started"
        case .stage1Completed(let n): return "Stage 1 done — \(n) candidates"
        case .stage2Started(let n): return "Stage 2 started over \(n) windows"
        case .stage2Progress(let i, let n): return "Stage 2 \(i)/\(n)"
        case .stage2Completed(let n): return "Stage 2 done — \(n) moments"
        case .rankingCompleted(let n): return "Ranking done — \(n) clips"
        case .composing: return "Composing reel"
        case .completed: return "Done"
        case .failed(let e): return "Failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Local-file share sheet

struct LocalFileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Stadium-light progress bar

/// Four thick segments that fill green in order as Stage 1 → Stage 2 →
/// Composition → Done. The current stage pulses; future stages are dim.
struct StadiumLightBar: View {
    let stage: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { i in
                segment(filled: i < stage,
                        active: i == stage,
                        failed: stage < 0 && i == 0)
            }
        }
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func segment(filled: Bool, active: Bool, failed: Bool) -> some View {
        let color: Color = {
            if failed { return Theme.danger }
            if filled { return Theme.success }
            if active { return Theme.accent }
            return Theme.bgCard
        }()
        Capsule()
            .fill(color)
            .opacity(active ? (pulse ? 1.0 : 0.55) : 1.0)
            .animation(active
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
    }
}
