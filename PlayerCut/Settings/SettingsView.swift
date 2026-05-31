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

    // Section 1 — Reel Audio
    @AppStorage(ReelSettingsKeys.includeGameAudio) private var includeGameAudio = true
    @AppStorage(ReelSettingsKeys.musicLevelDb)     private var musicLevelDb: Double = -4.5
    @AppStorage(ReelSettingsKeys.gameAudioLevelDb) private var gameAudioLevelDb: Double = -21
    @AppStorage(ReelSettingsKeys.duckDepthDb)      private var duckDepthDb: Double = 6
    @AppStorage(ReelSettingsKeys.gameAudioBoostDb) private var gameAudioBoostDb: Double = 5
    // Section 2 — Reel Pacing
    @AppStorage(ReelSettingsKeys.heroPacing)        private var heroPacing = true
    @AppStorage(ReelSettingsKeys.numHeroClips)      private var numHeroClips = 1
    @AppStorage(ReelSettingsKeys.heroDurationSec)   private var heroDurationSec: Double = 5
    @AppStorage(ReelSettingsKeys.fillerDurationSec) private var fillerDurationSec: Double = 2.5
    @AppStorage(ReelSettingsKeys.slowMoSpeed)       private var slowMoSpeed: Double = 0.4
    // Section 3 — Reel Order
    @AppStorage(ReelSettingsKeys.hookFirst) private var hookFirst = true
    // CapCut-parity S1 — Background
    @AppStorage(ReelSettingsKeys.backgroundMode)   private var backgroundModeRaw = BackgroundMode.auto.rawValue
    @AppStorage(ReelSettingsKeys.forceSegAllClips) private var forceSegAllClips = false
    @AppStorage(ReelSettingsKeys.showSegMask)      private var showSegMask = false
    // CapCut-parity S2 — Captions
    @AppStorage(ReelSettingsKeys.captionsEnabled)  private var captionsEnabled = true
    @AppStorage(ReelSettingsKeys.captionLocale)    private var captionLocale = "auto"
    @AppStorage(ReelSettingsKeys.captionPosition)  private var captionPositionRaw = CaptionPosition.bottom.rawValue
    // CapCut-parity S5 — Stage 1 debug
    @AppStorage(ReelSettingsKeys.forceSceneType)   private var forceSceneTypeRaw = SceneOverride.auto.rawValue
    @AppStorage(ReelSettingsKeys.usePoseSignal)    private var usePoseSignal = true
    // Templates — system-wide default ("" = system fallback, per-player
    // default wins regardless).
    @AppStorage(ReelSettingsKeys.selectedTemplateID) private var selectedTemplateID = ""

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
                        .accessibilityIdentifier("open-diagnostics")

                        // Section 1 — Reel Audio
                        sectionHeader("Reel audio")
                        reelCard {
                            Toggle("Include game audio", isOn: $includeGameAudio)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-include-game-audio")
                            dbSlider(title: "Music level",
                                     value: $musicLevelDb, in: -12 ... 0,
                                     id: "reel-music-level")
                            dbSlider(title: "Game audio level",
                                     value: $gameAudioLevelDb, in: -30 ... -6,
                                     id: "reel-game-audio-level")
                            dbSlider(title: "Duck depth on hit",
                                     value: $duckDepthDb, in: 3 ... 12,
                                     id: "reel-duck-depth")
                            dbSlider(title: "Game audio boost on hit",
                                     value: $gameAudioBoostDb, in: 0 ... 9,
                                     id: "reel-game-boost")
                        }
                        Text("A/B with music-only by turning Include game audio off.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        // Section 2 — Reel Pacing
                        sectionHeader("Reel pacing")
                        reelCard {
                            Toggle("Hero-emphasis pacing", isOn: $heroPacing)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-hero-pacing")
                            Stepper(value: $numHeroClips, in: 1 ... 2) {
                                HStack {
                                    Text("Hero clips").font(.pcBody)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(numHeroClips)")
                                        .font(.pcCaption.monospacedDigit())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .accessibilityIdentifier("reel-num-hero")
                            secSlider(title: "Hero clip duration",
                                      value: $heroDurationSec, in: 3 ... 7,
                                      unit: "s", id: "reel-hero-duration")
                            secSlider(title: "Filler clip duration",
                                      value: $fillerDurationSec, in: 1.5 ... 3.5,
                                      unit: "s", id: "reel-filler-duration")
                            secSlider(title: "Slow-mo speed",
                                      value: $slowMoSpeed, in: 0.3 ... 0.6,
                                      unit: "x", id: "reel-slowmo")
                        }
                        Text("Hero-emphasis gives the top play longer breathing room and slow-mo at the apex; uniform pacing keeps every clip the same.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        // Section 3 — Reel Order
                        sectionHeader("Reel order")
                        reelCard {
                            Toggle("Hook first (best play leads)",
                                   isOn: $hookFirst)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-hook-first")
                        }
                        Text("With Hook first on, the strongest moment opens the reel. Turn it off to keep clips in chronological order.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        // CapCut-parity S1 — Effects (background segmentation)
                        sectionHeader("Effects")
                        reelCard {
                            Picker("Background style",
                                   selection: $backgroundModeRaw) {
                                ForEach(BackgroundMode.allCases, id: \.rawValue) { m in
                                    Text(m.rawValue.capitalized).tag(m.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("reel-bg-mode")
                            Toggle("Force segmentation on every clip (debug)",
                                   isOn: $forceSegAllClips)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-bg-force-all")
                            Toggle("Show segmentation mask (debug)",
                                   isOn: $showSegMask)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-bg-show-mask")
                        }
                        Text("Cutout puts the kid over a blurred plate. Pop pushes the grade only on the kid. Auto picks per clip.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        // CapCut-parity S2 — Captions
                        sectionHeader("Captions")
                        reelCard {
                            Toggle("Auto captions", isOn: $captionsEnabled)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("reel-captions-enabled")
                            Picker("Position", selection: $captionPositionRaw) {
                                ForEach(CaptionPosition.allCases, id: \.rawValue) { p in
                                    Text(p.rawValue.capitalized).tag(p.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("reel-caption-position")
                            HStack {
                                Text("Locale").font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                TextField("auto", text: $captionLocale)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("reel-caption-locale")
                            }
                        }
                        Text("On-device speech recognition. \"auto\" uses the device locale; \"en-US\" / \"es-ES\" etc. force one.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)

                        // CapCut-parity S3 — Subscription
                        sectionHeader("Subscription")
                        reelCard {
                            HStack {
                                Text("Current plan").font(.pcBody)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(PricingGate.currentPlan.displayName)
                                    .font(.pcCaption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Button("Restore Purchases") {
                                Task { _ = await StoreKitManager.shared.restorePurchases() }
                            }
                            .accessibilityIdentifier("subscription-restore")
                            #if DEBUG
                            Button("Reset free-trial counter (debug)") {
                                PricingGate.resetFreeTrial()
                            }
                            .accessibilityIdentifier("subscription-reset-trial")
                            Picker("Force plan (debug)", selection: Binding(
                                get: { PricingGate.currentPlan.rawValue },
                                set: { PricingGate.setPlan(PricingPlan(rawValue: $0) ?? .freeTrial) })) {
                                ForEach(PricingPlan.allCases, id: \.rawValue) { p in
                                    Text(p.displayName).tag(p.rawValue)
                                }
                            }
                            .accessibilityIdentifier("subscription-force-plan")
                            #endif
                        }

                        // CapCut-parity S5 — Stage 1 debug
                        sectionHeader("Stage 1 debug")
                        reelCard {
                            Picker("Force scene type", selection: $forceSceneTypeRaw) {
                                ForEach(SceneOverride.allCases, id: \.rawValue) { s in
                                    Text(s.rawValue.capitalized).tag(s.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("stage1-force-scene")
                            Toggle("Use pose signal", isOn: $usePoseSignal)
                                .tint(Theme.accent)
                                .accessibilityIdentifier("stage1-use-pose")
                        }

                        // Templates — system-wide default template. Per-
                        // player default lives on PlayerProfile (set from
                        // the enrollment editor); this picker is the
                        // global fallback when no player default is set.
                        sectionHeader("Default template")
                        reelCard {
                            Picker("Template", selection: $selectedTemplateID) {
                                Text("System default")
                                    .tag("")
                                ForEach(TemplateRegistry.shared.list()) { t in
                                    Text(t.displayName).tag(t.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("settings-template-picker")
                            Text("Used when the player has no per-profile default. Tap a tile on the pre-record sheet to override per game.")
                                .font(.pcCaption)
                                .foregroundStyle(Theme.textSecondary)
                        }

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

    // MARK: - Reel Audio / Pacing / Order helpers

    @ViewBuilder
    private func reelCard<Content: View>(@ViewBuilder _ content: () -> Content)
        -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgCard,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func dbSlider(title: String,
                          value: Binding<Double>,
                          in range: ClosedRange<Double>,
                          id: String) -> some View {
        labeledSlider(title: title, value: value, in: range,
                      format: "%.1f dB", id: id)
    }

    private func secSlider(title: String,
                           value: Binding<Double>,
                           in range: ClosedRange<Double>,
                           unit: String,
                           id: String) -> some View {
        labeledSlider(title: title, value: value, in: range,
                      format: "%.1f \(unit)", id: id)
    }

    private func labeledSlider(title: String,
                               value: Binding<Double>,
                               in range: ClosedRange<Double>,
                               format: String,
                               id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.pcBody).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.pcCaption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
                .tint(Theme.accent)
                .accessibilityIdentifier(id)
        }
    }
}
