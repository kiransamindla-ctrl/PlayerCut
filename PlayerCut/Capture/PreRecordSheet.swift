//
//  PreRecordSheet.swift
//  PlayerCut/Capture
//
//  Shown when the parent taps "Record game", BEFORE the system camera
//  opens. Captures the two per-game choices that actually change the reel
//  — reel length (drives the highlight duration) and music vibe (drives
//  MusicLibrary.pick + edit style) — plus a quick framing reminder so the
//  footage is usable.
//
//  Flow: Record game → this sheet → Continue → system camera (CaptureView).
//
//  Quick-tips copy is authored here from the app's own recording guidance
//  (see WelcomeView / AssistedTierView); there is no PlayerCut-QuickTips.md
//  in the repo to load from.
//

import SwiftUI

/// The choices made on the pre-record sheet, handed to CaptureView.
struct PreRecordChoice {
    let length: ReelLength
    let vibe: MusicVibe
}

struct PreRecordSheet: View {
    let player: PlayerEnrollment
    var onContinue: (PreRecordChoice) -> Void
    var onCancel: () -> Void

    @State private var reelLength: ReelLength
    @State private var musicVibe: MusicVibe

    init(player: PlayerEnrollment,
         onContinue: @escaping (PreRecordChoice) -> Void,
         onCancel: @escaping () -> Void) {
        self.player = player
        self.onContinue = onContinue
        self.onCancel = onCancel
        _reelLength = State(initialValue: player.reelLengthPreference)
        _musicVibe = State(initialValue: player.musicVibe)
    }

    private let tips: [(icon: String, text: String)] = [
        ("rectangle.landscape.rotate", "Film in landscape on a steady mount — a tripod or railing beats handheld."),
        ("person.and.arrow.left.and.arrow.right", "Stand back ~10–15 ft and keep your whole player in frame. Don't zoom in and out."),
        ("sun.max", "Good, even light helps — try not to shoot straight into the sun."),
        ("clock.arrow.circlepath", "Record the whole game. PlayerCut finds the highlights for you."),
        ("bolt.fill", "For the fastest reel: keep the phone on a charger, on Wi-Fi, with PlayerCut open while it processes.")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Recording \(player.name). These apply to this game only.")
                            .font(.pcBody)
                            .foregroundStyle(Theme.textSecondary)

                        reelLengthSection
                        musicVibeSection
                        quickTipsSection
                    }
                    .padding(20)
                    .padding(.bottom, 8)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PCPillButton(title: "Continue",
                             systemImage: "camera.fill",
                             tint: Theme.primary,
                             height: 64) {
                    Haptic.tap()
                    onContinue(PreRecordChoice(length: reelLength, vibe: musicVibe))
                }
                .accessibilityIdentifier("prerecord-continue")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.bgDark)
            }
            .navigationTitle("Before you record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgDark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("CANCEL") {
                        Haptic.tap()
                        onCancel()
                    }
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: - Sections

    private var reelLengthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Reel length")
            Picker("Reel length", selection: $reelLength) {
                ForEach(ReelLength.allCases, id: \.self) { len in
                    Text(len.displayName).tag(len)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("prerecord-length")
        }
    }

    private var musicVibeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Music vibe")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 12) {
                ForEach(MusicVibe.allCases, id: \.self) { vibe in
                    Button {
                        Haptic.tap()
                        musicVibe = vibe
                    } label: {
                        Text(vibe.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(musicVibe == vibe ? Theme.primary : Theme.bgCard,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                            .foregroundStyle(musicVibe == vibe ? .white : Theme.textPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.card)
                                    .stroke(musicVibe == vibe ? Theme.accent : .clear,
                                            lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("prerecord-vibe-\(vibe.rawValue)")
                }
            }
        }
    }

    private var quickTipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Quick tips")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(tips, id: \.text) { tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        Text(tip.text)
                            .font(.pcBody)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgCard,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.pcCaption)
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
    }
}
