//
//  WelcomeView.swift
//  PlayerCut/Onboarding
//
//  First-run experience. Three-screen pager (hero → privacy → terms)
//  followed by the "use your old phone" screen. Both surfaces persist
//  a one-shot UserDefaults flag so they only appear on first run.
//

import SwiftUI

enum OnboardingKeys {
    static let termsAccepted     = "playercut.terms_accepted_v1"
    static let oldPhoneIntro     = "playercut.old_phone_intro_shown"
}

// MARK: - Welcome (3-screen pager + I Agree gate)

struct WelcomeView: View {
    var onAccepted: () -> Void

    @State private var page = 0
    @State private var nextStep: Step? = nil

    enum Step { case oldPhone, done }

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    heroPage.tag(0)
                    privacyPage.tag(1)
                    termsPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                bottomActions
            }
        }
        .fullScreenCover(item: $nextStep) { step in
            if step == .oldPhone {
                UseYourOldPhoneView {
                    UserDefaults.standard.set(true,
                                              forKey: OnboardingKeys.oldPhoneIntro)
                    nextStep = nil
                    onAccepted()
                }
            }
        }
    }

    // MARK: - Pages

    private var heroPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("PlayerCut")
                .font(.pcHero)
                .foregroundStyle(Theme.textPrimary)
                .textCase(.uppercase)
                .tracking(2)
            Rectangle().fill(Theme.accent).frame(width: 72, height: 6)
            Text("Mount your old phone.\nWalk away.\nGet your kid's highlights.")
                .font(.pcHeading)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Your kid's video\nstays on your phone.\nAlways.")
                .font(.pcTitle)
                .foregroundStyle(Theme.textPrimary)
            Text("PlayerCut never uploads raw video. Every cut runs on-device. Reels you choose to keep live in your Photos library.")
                .font(.pcBody)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var termsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Terms")
                .font(.pcTitle)
                .foregroundStyle(Theme.textPrimary)
                .textCase(.uppercase)
                .tracking(1.5)
            bullet("You own everything you record.")
            bullet("PlayerCut is for personal use only.")
            bullet("Don't record other kids without their parents' consent.")
            bullet("PlayerCut does not warrant fitness for officiating, scouting, or recruitment.")
            bullet("Diagnostics are aggregated counters only — no video, no images, no identifiers.")
            Spacer()
        }
        .padding(.horizontal, 32)
        .accessibilityIdentifier("terms-page")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 8)
            Text(text)
                .font(.pcBody)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Bottom actions

    private var bottomActions: some View {
        VStack(spacing: 12) {
            if page < 2 {
                PCPillButton(title: "Next",
                             systemImage: "arrow.right.circle.fill",
                             tint: Theme.primary,
                             height: 60) {
                    withAnimation { page += 1 }
                }
                .accessibilityIdentifier("onboarding-next")
            } else {
                PCPillButton(title: "I agree",
                             systemImage: "checkmark.circle.fill",
                             tint: Theme.primary,
                             height: 60) {
                    Haptic.success()
                    UserDefaults.standard.set(true,
                                              forKey: OnboardingKeys.termsAccepted)
                    nextStep = .oldPhone
                }
                .accessibilityIdentifier("terms-agree")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

extension WelcomeView.Step: Identifiable {
    var id: Self { self }
}

// MARK: - Use Your Old Phone

struct UseYourOldPhoneView: View {
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "iphone.gen3.badge.play")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 24)

                    Text("Use your old phone.")
                        .font(.pcTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    Text("PlayerCut works best on a phone you don't need during the game. Most parents use an old iPhone from a drawer — battery doesn't have to be great, just enough for a half.")
                        .font(.pcBody)
                        .foregroundStyle(Theme.textSecondary)

                    Divider().background(Theme.bgCard)

                    Text("Setting up the old phone")
                        .font(.pcHeading)
                        .foregroundStyle(Theme.textPrimary)

                    step(num: 1, text: "Sign in to the old phone with the same Apple ID as your daily phone. Reels save to iCloud Photos either way; this just keeps your library in one place.")
                    step(num: 2, text: "Install PlayerCut on the old phone from the App Store.")
                    step(num: 3, text: "Enroll your child on the old phone — name, jersey number, jersey color, selfie. Takes about 90 seconds.")
                    step(num: 4, text: "Mount the old phone on a tripod at the sideline. Land­scape. PlayerCut will auto-start recording 10 seconds after it sees a stable mount.")
                    step(num: 5, text: "Walk away. The reel will be in your Photos library by the time you're back at the car.")

                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 28)
            }

            VStack {
                Spacer()
                PCPillButton(title: "Got it",
                             systemImage: "checkmark.circle.fill",
                             tint: Theme.primary,
                             height: 60) {
                    Haptic.tap()
                    onContinue()
                }
                .accessibilityIdentifier("old-phone-got-it")
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .accessibilityIdentifier("use-your-old-phone")
    }

    private func step(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            Text(text)
                .font(.pcBody)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
