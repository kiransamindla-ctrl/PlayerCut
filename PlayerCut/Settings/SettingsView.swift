//
//  SettingsView.swift
//  PlayerCut/Settings
//
//  Global app settings. UserDefaults-backed via @AppStorage so the
//  toggles persist across launches without a separate store layer.
//

import SwiftUI

enum SettingsKeys {
    static let autoStartEnabled = "playercut.auto_start_enabled"
    static let autoStopEnabled  = "playercut.auto_stop_enabled"
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // OFF by default — auto-start is a secondary convenience that
    // runs alongside (never instead of) the manual record button.
    @AppStorage(SettingsKeys.autoStartEnabled) private var autoStartEnabled = false
    @AppStorage(SettingsKeys.autoStopEnabled)  private var autoStopEnabled  = true
    /// Experimental AVAssetWriter recording path (Section 2 of the
    /// stock-quality build). Default OFF — flip on to A/B against the
    /// legacy AVCaptureMovieFileOutput path during the side-by-side
    /// device gate. Once verified on hardware, the legacy path will
    /// be removed and this toggle disappears.
    @AppStorage(WriterCaptureFlag.defaultsKey)
    private var writerCaptureEnabled = false

    @State private var presentingDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        BackgroundRefreshBanner()
                        sectionHeader("Capture automation")
                        VStack(spacing: 0) {
                            settingsRow {
                                Toggle("Auto-start when mounted",
                                       isOn: $autoStartEnabled)
                                    .tint(Theme.accent)
                                    .font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Divider().background(Theme.bgDark)
                            settingsRow {
                                Toggle("Auto-stop when motion stops",
                                       isOn: $autoStopEnabled)
                                    .tint(Theme.accent)
                                    .font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .pcCard()
                        Text("When auto-start is on, PlayerCut watches for the phone being placed on a tripod and begins recording after a 3-second grace period.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        sectionHeader("Experimental")
                        VStack(spacing: 0) {
                            settingsRow {
                                Toggle("Writer-based capture (HEVC ~45 Mbps)",
                                       isOn: $writerCaptureEnabled)
                                    .tint(Theme.accent)
                                    .font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .pcCard()
                        Text("Records via AVCaptureVideoDataOutput + AVAssetWriter to match the stock Camera app's bitrate and color tagging. Default OFF until verified side-by-side on device. Flip ON, record a clip, compare with the stock Camera, then leave on or flip off based on what looks better.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        sectionHeader("Privacy")
                        Button {
                            Haptic.tap()
                            presentingDiagnostics = true
                        } label: {
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                Text("Diagnostics")
                                    .font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(Theme.bgCard,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        }
                        .buttonStyle(.plain)
                        Text("PlayerCut never stores your child's video. Reels live in your Photos. Raw recordings are deleted the moment the reel is made.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgDark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") {
                        Haptic.tap()
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.accent)
                }
            }
            .sheet(isPresented: $presentingDiagnostics) {
                DiagnosticsView()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.pcCaption)
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
    }

    private func settingsRow<Content: View>(@ViewBuilder _ content: () -> Content)
        -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
    }
}
