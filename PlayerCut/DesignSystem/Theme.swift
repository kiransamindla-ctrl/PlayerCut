//
//  Theme.swift
//  PlayerCut/DesignSystem
//
//  Central design tokens. Don't sprinkle hex literals or magic numbers
//  through views — pull from here so the sports-bold language stays
//  consistent and a redesign can be done in one file.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Colors

enum Theme {

    /// Stadium green. Primary CTA color.
    static let primary       = Color(hex: 0x1B5E20)
    /// High-energy orange. Underlines, accents, badges, attention pulls.
    static let accent        = Color(hex: 0xFF6F00)
    /// Page background — near-black, not pure black so cards still pop.
    static let bgDark        = Color(hex: 0x0A0A0A)
    /// Card surface on bgDark.
    static let bgCard        = Color(hex: 0x1A1A1A)
    /// Text on dark surfaces.
    static let textPrimary   = Color(hex: 0xFFFFFF)
    /// Secondary text, meta, captions.
    static let textSecondary = Color(hex: 0xA0A0A0)
    static let success       = Color(hex: 0x4CAF50)
    static let danger        = Color(hex: 0xF44336)

    // MARK: - Radii

    enum Radius {
        /// Card corners (player cards, game cards, status chips).
        static let card: CGFloat = 16
        /// Pill buttons — derived from height/2 in practice but we
        /// pin a default so smaller chips line up with the big CTAs.
        static let pill: CGFloat = 28
    }

    // MARK: - Shadows

    enum Shadow {
        static let card = ShadowToken(color: .black.opacity(0.5),
                                      radius: 8, x: 0, y: 4)
        static let cta = ShadowToken(color: .black.opacity(0.4),
                                     radius: 12, x: 0, y: 6)
    }
}

struct ShadowToken {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Type scale

extension Font {
    /// 48 pt black — RootView hero, post-game headlines.
    static let pcHero    = Font.system(size: 48, weight: .black, design: .default)
    /// 28 pt bold — section titles, player names, primary CTAs.
    static let pcTitle   = Font.system(size: 28, weight: .bold, design: .default)
    /// 20 pt semibold — headings on cards.
    static let pcHeading = Font.system(size: 20, weight: .semibold, design: .default)
    /// 17 pt regular — body text.
    static let pcBody    = Font.system(size: 17, weight: .regular, design: .default)
    /// 13 pt medium — captions, meta.
    static let pcCaption = Font.system(size: 13, weight: .medium, design: .default)
}

// MARK: - View modifiers

extension View {
    func pcCard() -> some View {
        self.background(Theme.bgCard,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .shadow(token: Theme.Shadow.card)
    }

    func pcShadow(_ token: ShadowToken) -> some View {
        self.shadow(token: token)
    }

    fileprivate func shadow(token: ShadowToken) -> some View {
        self.shadow(color: token.color,
                    radius: token.radius,
                    x: token.x,
                    y: token.y)
    }
}

// MARK: - Primary pill button

/// Oversized pill button — the one primary action per screen.
struct PCPillButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.primary
    var height: CGFloat = 64
    var fullWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 22, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.system(size: 22, weight: .black))
                    .tracking(1.5)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 24)
            .foregroundStyle(Theme.textPrimary)
            .background(tint, in: Capsule())
            .shadow(token: Theme.Shadow.cta)
        }
        .buttonStyle(.plain)
    }
}

/// Outline counterpart to PCPillButton — secondary CTAs.
struct PCOutlinePillButton: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = Theme.textPrimary
    var height: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 19, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .tracking(1.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 24)
            .foregroundStyle(color)
            .overlay(
                Capsule().stroke(color.opacity(0.8), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status chip

/// Loud uppercase pill used for transient state — RECORDING, MOUNTED, etc.
struct PCStatusChip: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = Theme.textSecondary
    var foreground: Color = Theme.textPrimary

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 14, weight: .bold))
            }
            Text(title.uppercased())
                .font(.system(size: 14, weight: .black))
                .tracking(1.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(foreground)
        .background(color.opacity(0.95), in: Capsule())
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex         & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Haptics

enum Haptic {
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
