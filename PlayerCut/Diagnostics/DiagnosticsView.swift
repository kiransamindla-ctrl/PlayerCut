//
//  DiagnosticsView.swift
//  PlayerCut/Diagnostics
//
//  User-visible diagnostics screen. Three goals:
//
//   1. Make the app's behavior LEGIBLE to the user. They paid for a
//      subscription; they deserve to see whether the BG processing is
//      actually working on their device.
//
//   2. Provide a pre-built share path so users can email aggregate
//      diagnostics to support if something is going wrong. NEVER
//      auto-upload — the user must explicitly tap share, then choose where.
//
//   3. Provide a "reset" button so privacy-conscious users can wipe
//      everything.
//

import SwiftUI

struct DiagnosticsView: View {
    @State private var snapshot: DiagnosticsSnapshot?
    @State private var exportData: Data?
    @State private var showingShareSheet = false
    @State private var showingResetConfirm = false

    var body: some View {
        List {
            if let snap = snapshot {
                ReelOutcomesSection(counters: snap.counters)
                BackgroundTasksSection(counters: snap.counters)
                PerformanceSection(durations: snap.durations)
                CaptureHealthSection(counters: snap.counters)
                FooterSection(showingShareSheet: $showingShareSheet,
                              exportData: $exportData,
                              showingResetConfirm: $showingResetConfirm,
                              snapshot: snap)
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showingShareSheet) {
            if let data = exportData {
                ShareSheet(items: [
                    DiagnosticsExportFile(data: data)
                ])
            }
        }
        .confirmationDialog(
            "Erase all diagnostics data?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase", role: .destructive) {
                Task {
                    await DiagnosticsStore.shared.reset()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Counters and timings stored on this device will be removed.")
        }
    }

    private func refresh() async {
        snapshot = await DiagnosticsStore.shared.currentSnapshot()
    }
}

// MARK: - Sections

private struct ReelOutcomesSection: View {
    let counters: [String: Int]

    var completed: Int { counters[CounterKey.reelsCompleted.rawValue] ?? 0 }
    var failed: Int { counters[CounterKey.reelsFailed.rawValue] ?? 0 }
    var resumed: Int { counters[CounterKey.reelsRetriedFromResume.rawValue] ?? 0 }
    var successRate: Double {
        let total = completed + failed
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        Section("Reels") {
            HStack {
                Text("Completed")
                Spacer()
                Text("\(completed)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Failed")
                Spacer()
                Text("\(failed)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Resumed from saved state")
                Spacer()
                Text("\(resumed)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Success rate")
                Spacer()
                Text(percent(successRate)).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ x: Double) -> String {
        String(format: "%.0f%%", x * 100)
    }
}

private struct BackgroundTasksSection: View {
    let counters: [String: Int]

    var submitted: Int { counters[CounterKey.bgTaskSubmitted.rawValue] ?? 0 }
    var handled: Int { counters[CounterKey.bgTaskHandled.rawValue] ?? 0 }
    var expired: Int { counters[CounterKey.bgTaskExpired.rawValue] ?? 0 }
    var fallback: Int {
        counters[CounterKey.foregroundFallbackCompleted.rawValue] ?? 0
    }

    var grantRate: Double {
        guard submitted > 0 else { return 0 }
        return Double(handled) / Double(submitted)
    }

    var body: some View {
        Section {
            HStack {
                Text("BG tasks submitted")
                Spacer()
                Text("\(submitted)").foregroundStyle(.secondary)
            }
            HStack {
                Text("BG tasks granted")
                Spacer()
                Text("\(handled)").foregroundStyle(.secondary)
            }
            HStack {
                Text("BG tasks expired mid-run")
                Spacer()
                Text("\(expired)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Foreground fallbacks completed")
                Spacer()
                Text("\(fallback)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Grant rate")
                Spacer()
                Text(grantRateText).foregroundStyle(.secondary)
            }
        } header: {
            Text("Background processing")
        } footer: {
            Text("iOS decides whether to grant background time. If the grant rate is low, your reels may take longer to process — they'll finish next time you open the app.")
        }
    }

    private var grantRateText: String {
        guard submitted > 0 else { return "—" }
        return String(format: "%.0f%%", grantRate * 100)
    }
}

private struct PerformanceSection: View {
    let durations: [String: DurationBucket]

    var body: some View {
        Section("Performance") {
            row("Stage 1", key: DurationKey.stage1.rawValue)
            row("Stage 2", key: DurationKey.stage2.rawValue)
            row("Composition", key: DurationKey.composition.rawValue)
            row("Total pipeline", key: DurationKey.totalPipeline.rawValue)
        }
    }

    @ViewBuilder
    private func row(_ title: String, key: String) -> some View {
        if let bucket = durations[key], bucket.count > 0 {
            HStack {
                Text(title)
                Spacer()
                Text("med \(format(bucket.p50))  ·  n=\(bucket.count)")
                    .foregroundStyle(.secondary)
                    .font(.footnote.monospacedDigit())
            }
        } else {
            HStack {
                Text(title)
                Spacer()
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(m)m \(s)s"
    }
}

private struct CaptureHealthSection: View {
    let counters: [String: Int]

    var body: some View {
        Section("Capture") {
            HStack {
                Text("Games recorded")
                Spacer()
                Text("\(counters[CounterKey.gamesRecorded.rawValue] ?? 0)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Interruptions during capture")
                Spacer()
                Text("\(counters[CounterKey.captureInterruptions.rawValue] ?? 0)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FooterSection: View {
    @Binding var showingShareSheet: Bool
    @Binding var exportData: Data?
    @Binding var showingResetConfirm: Bool
    let snapshot: DiagnosticsSnapshot

    var body: some View {
        Section {
            Button {
                if let data = try? snapshot.exportJSON() {
                    exportData = data
                    showingShareSheet = true
                }
            } label: {
                Label("Share diagnostics", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                showingResetConfirm = true
            } label: {
                Label("Erase all diagnostics", systemImage: "trash")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Diagnostics are stored only on this device. Sharing creates a JSON file you can email to support — nothing is uploaded automatically.")
        }
    }
}

// MARK: - Share sheet bridge + temp-file wrapper

import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context)
        -> UIActivityViewController {
        UIActivityViewController(activityItems: items,
                                 applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}

/// Writes the JSON to a temp file with a sensible filename so the share
/// sheet shows "diagnostics-2026-05-05.json" rather than a UUID. The
/// temp file is auto-cleaned by the OS.
final class DiagnosticsExportFile: NSObject, UIActivityItemSource {

    let data: Data
    let url: URL

    init(data: Data) {
        self.data = data
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let datePart = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playercut-diagnostics-\(datePart).json")
        try? data.write(to: url, options: .atomic)
        self.url = url
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController)
        -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?)
        -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?)
        -> String { "PlayerCut diagnostics" }
}
