//
//  PaywallView.swift
//  PlayerCut/Pricing
//
//  Sheet shown after the 3rd free reel completes. Five plan cards
//  (Single Annual flagged "Most popular", Lifetime last). Real
//  StoreKit 2 wiring is stubbed.
//

import SwiftUI

struct PaywallView: View {
    var onSubscribe: (PricingPlan) -> Void
    var onMaybeLater: () -> Void

    private let plans: [PricingPlan] = [
        .singleMonthly,
        .familyMonthly,
        .singleAnnual,
        .familyAnnual,
        .lifetime
    ]

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    ForEach(plans, id: \.self) { plan in
                        planCard(plan)
                    }

                    Button {
                        Haptic.tap()
                        onMaybeLater()
                    } label: {
                        Text("MAYBE LATER")
                            .font(.system(size: 14, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paywall-maybe-later")
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep cutting reels.")
                .font(.pcTitle)
                .foregroundStyle(Theme.textPrimary)
            Text("You've used your free reels. Pick a plan to keep going. No upload, no ads, just reels.")
                .font(.pcBody)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 8)
    }

    private func planCard(_ plan: PricingPlan) -> some View {
        let isHighlight = (plan == .singleAnnual)
        return Button {
            Haptic.success()
            // TODO StoreKit2-LAUNCH: replace with real Product purchase
            PricingGate.setPlan(plan)
            onSubscribe(plan)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isHighlight {
                        Text("MOST POPULAR")
                            .font(.system(size: 11, weight: .black))
                            .tracking(1.3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(Theme.bgDark)
                    }
                    Text(plan.displayName)
                        .font(.pcHeading)
                        .foregroundStyle(Theme.textPrimary)
                    Text(plan.includesLine)
                        .font(.pcCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(plan.priceLine)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(isHighlight ? Theme.accent : Theme.textPrimary)
            }
            .padding(16)
            .background(Theme.bgCard,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(isHighlight ? Theme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall-plan-\(plan.rawValue)")
    }
}
