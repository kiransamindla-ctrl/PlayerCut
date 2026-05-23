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

    // Capture-side toggles were removed when PlayerCut switched to the
    // system camera (UIImagePickerController). Auto-start, auto-stop,
    // and the experimental writer-capture path were all features of
    // the retired custom AVCaptureSession.

    @State private var presentingDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        BackgroundRefreshBanner()
                        sectionHeader("Capture")
                        Text("PlayerCut uses the iPhone's system Camera for recording — the same UI as the stock Camera app. Tap Record on the home screen, the system camera opens, record and stop yourself, then PlayerCut produces the highlight reel.")
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
