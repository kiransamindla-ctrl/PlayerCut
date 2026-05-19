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

    @AppStorage(SettingsKeys.autoStartEnabled) private var autoStartEnabled = true
    @AppStorage(SettingsKeys.autoStopEnabled)  private var autoStopEnabled  = true

    @State private var presentingDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-start when mounted", isOn: $autoStartEnabled)
                    Toggle("Auto-stop when motion stops", isOn: $autoStopEnabled)
                } header: {
                    Text("Capture automation")
                } footer: {
                    Text("When auto-start is on, PlayerCut watches for the phone being placed on a tripod and begins recording after a 3-second grace period.")
                }

                Section {
                    Button {
                        presentingDiagnostics = true
                    } label: {
                        Label("Diagnostics", systemImage: "chart.bar")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("PlayerCut never stores your child's video. Reels live in your Photos. Raw recordings are deleted the moment the reel is made.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $presentingDiagnostics) {
                DiagnosticsView()
            }
        }
    }
}
