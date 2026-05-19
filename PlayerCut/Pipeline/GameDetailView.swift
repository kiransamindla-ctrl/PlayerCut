//
//  GameDetailView.swift
//  PlayerCut/Pipeline
//
//  Minimal per-game screen for end-to-end testing. Plays back the reel
//  from the user's Photos library; otherwise shows the current pipeline
//  status. If the reel exists only as a local fallback (Photos access was
//  denied), exposes a Try again button to re-request permission and save.
//

import AVKit
import Photos
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

    @State private var playerItem: AVPlayerItem?
    @State private var loadedAssetId: String?

    @State private var retryingPermission = false

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
        if game.status == .completed {
            completedContent(for: game)
        } else {
            processingContent(for: game)
        }
    }

    // MARK: - Completed state

    @ViewBuilder
    private func completedContent(for game: GameSession) -> some View {
        if let assetId = game.exportedReelAssetId {
            // Reel is in Photos. Load and play.
            VStack(spacing: 12) {
                if let item = playerItem {
                    VideoPlayer(player: AVPlayer(playerItem: item))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                } else {
                    ProgressView("Loading reel from Photos…")
                        .frame(maxWidth: .infinity)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .task { await loadPlayerItem(assetId: assetId) }
                }
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
                if let asset = PhotosLibraryService.fetchAsset(localIdentifier: assetId) {
                    PHAssetShareSheet(asset: asset)
                }
            }
        } else if let fallback = game.localReelFallbackURL {
            permissionDeniedFallback(for: game, fallback: fallback)
        } else {
            Text("Reel is missing.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    @ViewBuilder
    private func permissionDeniedFallback(for game: GameSession,
                                          fallback: URL) -> some View {
        VStack(spacing: 12) {
            VideoPlayer(player: AVPlayer(url: fallback))
                .frame(maxWidth: .infinity)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                Label("Allow Photos access to save your reel",
                      systemImage: "photo.on.rectangle")
                    .font(.callout.bold())
                Text("PlayerCut needs permission to add your reel to your Photos library. Until then, it's only on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    retrySaveToPhotos(game: game, fallback: fallback)
                } label: {
                    if retryingPermission {
                        ProgressView().tint(.white)
                    } else {
                        Text("Try again")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(retryingPermission)
            }
            .padding()
            .background(Color.orange.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            Spacer()
        }
    }

    // MARK: - Processing state

    @ViewBuilder
    private func processingContent(for game: GameSession) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(statusLabel(game.status))
                .font(.headline)
            Text("Started \(game.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    // MARK: - Helpers

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

    private func loadPlayerItem(assetId: String) async {
        guard loadedAssetId != assetId else { return }
        loadedAssetId = assetId
        guard let asset = PhotosLibraryService.fetchAsset(localIdentifier: assetId) else {
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        let item: AVPlayerItem? = await withCheckedContinuation { cont in
            PHImageManager.default().requestPlayerItem(forVideo: asset,
                                                       options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
        await MainActor.run { self.playerItem = item }
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

    private func retrySaveToPhotos(game: GameSession, fallback: URL) {
        guard !retryingPermission else { return }
        retryingPermission = true
        Task {
            let result = await PhotosLibraryService.saveReel(fileURL: fallback)
            switch result {
            case .saved(let id):
                var updated = game
                updated.exportedReelAssetId = id
                updated.localReelFallbackURL = nil
                try? await coordinator.store.upsert(updated)
                try? FileManager.default.removeItem(at: fallback)
                await coordinator.refresh()
                self.game = updated
            case .permissionDenied:
                // Stay on the fallback path.
                break
            }
            retryingPermission = false
        }
    }
}

// MARK: - Photos-asset share sheet

struct PHAssetShareSheet: UIViewControllerRepresentable {
    let asset: PHAsset

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: "public.movie",
            fileOptions: [],
            visibility: .all) { completion in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestAVAsset(forVideo: asset,
                                                       options: options) { avAsset, _, _ in
                    if let urlAsset = avAsset as? AVURLAsset {
                        completion(urlAsset.url, false, nil)
                    } else {
                        completion(nil, false,
                                   NSError(domain: "PHAssetShareSheet", code: 1))
                    }
                }
                return nil
            }
        return UIActivityViewController(activityItems: [provider],
                                        applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
