//
//  BackgroundRefreshGuidance.swift
//  PlayerCut/Settings
//
//  Section C: detect UIApplication.backgroundRefreshStatus and surface
//  a non-blocking banner when it's off. iOS still allows foreground
//  capture either way — this is guidance, never a hard requirement.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum BackgroundRefreshGuidance {

    /// True when the user should be nudged toward enabling Background
    /// App Refresh. The capture path works without it; pipelines just
    /// have a harder time finishing on time after the user backgrounds
    /// the app.
    static var needsNudge: Bool {
        #if canImport(UIKit)
        switch UIApplication.shared.backgroundRefreshStatus {
        case .denied, .restricted: return true
        default:                   return false
        }
        #else
        return false
        #endif
    }

    static var statusLabel: String {
        #if canImport(UIKit)
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:  return "available"
        case .denied:     return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    static func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

struct BackgroundRefreshBanner: View {
    var body: some View {
        if BackgroundRefreshGuidance.needsNudge {
            Button {
                Haptic.tap()
                BackgroundRefreshGuidance.openSettings()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on Background App Refresh")
                            .font(.pcBody.bold())
                            .foregroundStyle(Theme.textPrimary)
                        Text("So your reel finishes even if you leave the app.")
                            .font(.pcCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                .background(Theme.bgCard,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bg-refresh-banner")
        } else {
            EmptyView()
        }
    }
}
