//
//  GameDetailView.swift
//  PlayerCut/Pipeline
//
//  Minimal per-game screen for end-to-end testing. Plays back the reel if
//  one was produced; otherwise shows the current pipeline status.
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
        Group {
            if let game {
                content(for: game)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Game")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(refreshTimer) { _ in Task { await reload() } }
    }

    @ViewBuilder
    private func content(for game: GameSession) -> some View {
        if game.status == .completed, let url = game.exportedReelURL {
            VStack(spacing: 12) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                Button {
                    presentingShare = true
                } label: {
                    Label("Share reel", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                Spacer()
            }
            .sheet(isPresented: $presentingShare) {
                ShareSheet(items: [url])
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text(statusLabel(game.status))
                    .font(.headline)
                Text("Started \(game.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Debug-only: surface a manual trigger while BG task
                // heuristics are still warming up on this device.
                if game.status == .awaitingProcessing || game.status == .failed {
                    Button {
                        runNow(gameID: game.id)
                    } label: {
                        Label(manualRun == nil ? "Process Now" : "Processing…",
                              systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(manualRun != nil)
                    .padding(.horizontal)
                }

                if let manualRunLog {
                    Text(manualRunLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
        }
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

    private func statusLabel(_ status: GameStatus) -> String {
        switch status {
        case .recording: return "Recording…"
        case .awaitingProcessing: return "Waiting to process"
        case .stage1Running: return "Processing — Stage 1 (coarse detection)"
        case .stage2Running: return "Processing — Stage 2 (player ID)"
        case .composing: return "Processing — composing reel"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func reload() async {
        await coordinator.refresh()
        game = coordinator.games.first { $0.id == gameID }
    }
}

