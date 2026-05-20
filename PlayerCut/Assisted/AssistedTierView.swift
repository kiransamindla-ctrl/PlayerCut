//
//  AssistedTierView.swift
//  PlayerCut/Assisted
//
//  Two-column Standard vs Assisted comparison, surfaced once after the
//  first enrollment completes. Persists a UserDefaults flag so it
//  doesn't reappear on subsequent launches.
//

import SwiftUI

enum AssistedKeys {
    static let assistedTierShown = "playercut.assisted_tier_shown"
}

struct AssistedTierView: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Two ways to use PlayerCut")
                        .font(.pcTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .padding(.top, 16)

                    columns

                    NavigationLink {
                        RecommendedGearView()
                    } label: {
                        HStack {
                            Image(systemName: "bag.fill")
                            Text("See recommended gear").bold()
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .foregroundStyle(Theme.textPrimary)
                        .background(Theme.bgCard,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(height: 100)
                }
                .padding(.horizontal, 20)
            }
            VStack {
                Spacer()
                PCPillButton(title: "Got it",
                             systemImage: "checkmark.circle.fill",
                             tint: Theme.primary,
                             height: 60) {
                    UserDefaults.standard.set(true,
                                              forKey: AssistedKeys.assistedTierShown)
                    onDismiss()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 12) {
            tierColumn(title: "Standard",
                       price: "Built in",
                       bullets: [
                        "Your phone on a tripod",
                        "OCR + color + face ID",
                        "Solid in most conditions"
                       ],
                       tint: Theme.bgCard)
            tierColumn(title: "Assisted",
                       price: "Add a beacon",
                       bullets: [
                        "BLE beacon on the kid",
                        "Locks identification to 100%",
                        "Works through occlusion",
                        "Best in crowded games"
                       ],
                       tint: Theme.primary.opacity(0.5))
        }
    }

    private func tierColumn(title: String,
                            price: String,
                            bullets: [String],
                            tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.pcCaption)
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
            Text(price)
                .font(.pcHeading)
                .foregroundStyle(Theme.textPrimary)
            ForEach(bullets, id: \.self) { b in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text(b)
                        .font(.pcBody)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

// MARK: - Recommended gear

struct RecommendedGearView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Accessory.Category.allCases, id: \.self) { cat in
                    let items = AccessoryCatalog.all.filter { $0.category == cat }
                    if !items.isEmpty {
                        Text(cat.rawValue.uppercased())
                            .font(.pcCaption)
                            .tracking(1.5)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 12) {
                            ForEach(items) { item in
                                accessoryRow(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bgDark.ignoresSafeArea())
        .navigationTitle("RECOMMENDED GEAR")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func accessoryRow(_ item: Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.pcBody.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(item.summary)
                    .font(.pcCaption)
                    .foregroundStyle(Theme.textSecondary)
                Text(item.priceRange)
                    .font(.pcCaption.bold())
                    .foregroundStyle(Theme.success)
                if let url = item.affiliateURL {
                    Link(destination: url) {
                        Text("SHOW ON AMAZON")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(Theme.textPrimary)
                            .background(Theme.primary, in: Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}
