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
/// `templateID` carries the user's preset pick — the orchestrator
/// resolves it to a full `ReelTemplate` at compose time. `vibe` is
/// derived from the template so MusicLibrary picks from the matching
/// pool; we keep it on the struct for back-compat with existing
/// callers that read `choice.vibe`.
struct PreRecordChoice {
    let length: ReelLength
    let vibe: MusicVibe
    let templateID: String
}

struct PreRecordSheet: View {
    let player: PlayerEnrollment
    var onContinue: (PreRecordChoice) -> Void
    var onCancel: () -> Void

    @State private var reelLength: ReelLength
    @State private var selectedTemplateID: String

    init(player: PlayerEnrollment,
         onContinue: @escaping (PreRecordChoice) -> Void,
         onCancel: @escaping () -> Void) {
        self.player = player
        self.onContinue = onContinue
        self.onCancel = onCancel
        _reelLength = State(initialValue: player.reelLengthPreference)
        // Initial template pick: player default → last-used (ReelSettings) →
        // system default. Mirrors TemplateRegistry.resolve so what the user
        // sees pre-selected is what would have been applied anyway.
        let initialID: String = {
            if let id = player.defaultTemplateID, !id.isEmpty { return id }
            let stored = ReelSettings.current.selectedTemplateID
            if !stored.isEmpty { return stored }
            return TemplateRegistry.defaultTemplateID
        }()
        _selectedTemplateID = State(initialValue: initialID)
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
                        templateGallerySection
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
                    // Persist the user's template pick to ReelSettings so
                    // the orchestrator + Settings → Templates see the
                    // same selection on the next session.
                    UserDefaults.standard.set(
                        selectedTemplateID,
                        forKey: ReelSettingsKeys.selectedTemplateID)
                    let vibe = TemplateRegistry.shared.get(id: selectedTemplateID)?.musicVibe
                        ?? player.musicVibe
                    onContinue(PreRecordChoice(
                        length: reelLength, vibe: vibe,
                        templateID: selectedTemplateID))
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

    private var templateGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Style")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(TemplateRegistry.shared.list()) { template in
                        templateTile(template)
                    }
                }
                .padding(.horizontal, 2)  // breathing room for the focus ring
            }
            .accessibilityIdentifier("prerecord-template-gallery")
        }
    }

    private func templateTile(_ template: ReelTemplate) -> some View {
        let isSelected = selectedTemplateID == template.id
        let isPlayerDefault = (player.defaultTemplateID == template.id)
        return Button {
            Haptic.tap()
            selectedTemplateID = template.id
        } label: {
            VStack(spacing: 8) {
                // PR #10 — real keystone-rendered thumbnail JPG (600x800
                // captured from sample-video runs in
                // TemplateThumbnailRenderTests). Falls back to the
                // template's SF symbol when the bundle doesn't carry the
                // JPG (older installs or unbundled debug variants).
                Group {
                    if let uiImg = UIImage(named: template.id) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: template.thumbnailAsset)
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                    }
                }
                    .frame(width: 110, height: 140)
                    .clipped()
                    .background(isSelected ? Theme.primary : Theme.bgCard,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(isSelected ? Theme.accent : .clear,
                                    lineWidth: 3))
                    .overlay(alignment: .topTrailing) {
                        if isPlayerDefault {
                            Text("DEFAULT")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(0.8)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.black)
                                .padding(6)
                        }
                    }
                Text(template.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 110)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("prerecord-template-\(template.id)")
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
