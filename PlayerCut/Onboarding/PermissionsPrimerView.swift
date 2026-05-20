//
//  PermissionsPrimerView.swift
//  PlayerCut/Onboarding
//
//  Section F: one-screen explainer of every permission PlayerCut
//  will ask for. Shown after T&C, before first capture. Persists
//  completion in UserDefaults("playercut.permissions_primer_done").
//
//  Bluetooth is intentionally omitted from the upfront ask — beacon
//  pairing only requests it during the Assisted-tier enrollment
//  step (Section D, least privilege).
//

import AVFoundation
import Photos
import SwiftUI
import UserNotifications

enum PermissionPrimerKeys {
    static let primerDone = "playercut.permissions_primer_done"
}

struct PermissionsPrimerView: View {
    var onContinue: () -> Void

    @State private var requesting = false

    var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Permissions")
                        .font(.pcTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .padding(.top, 24)

                    Text("PlayerCut asks for the least it needs. Here's why.")
                        .font(.pcBody)
                        .foregroundStyle(Theme.textSecondary)

                    permissionRow(
                        icon: "video.fill",
                        title: "Camera",
                        body: "To record the game.")
                    permissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        body: "To find the most exciting moments and add game sound to your reel.")
                    permissionRow(
                        icon: "photo.fill",
                        title: "Photos (Add Only)",
                        body: "To save your reel. We can't see your other photos.")
                    permissionRow(
                        icon: "bell.fill",
                        title: "Notifications",
                        body: "To tell you when your reel is ready.")
                    permissionRow(
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        title: "Background App Refresh",
                        body: "So your reel finishes if you switch apps. We'll deep-link you to Settings to enable it.")
                    permissionRow(
                        icon: "dot.radiowaves.left.and.right",
                        title: "Bluetooth (Assisted tier only)",
                        body: "Only if you pair a beacon to your child later. Not asked now.")

                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 28)
            }

            VStack {
                Spacer()
                PCPillButton(
                    title: requesting ? "Asking…" : "Continue",
                    systemImage: requesting ? nil : "checkmark.circle.fill",
                    tint: Theme.primary,
                    height: 60
                ) {
                    Task { await requestAllAndFinish() }
                }
                .disabled(requesting)
                .opacity(requesting ? 0.6 : 1)
                .accessibilityIdentifier("permissions-continue")
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .accessibilityIdentifier("permissions-primer")
    }

    private func permissionRow(icon: String,
                               title: String,
                               body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.pcBody.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(body)
                    .font(.pcCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Requests

    private func requestAllAndFinish() async {
        requesting = true
        defer {
            requesting = false
            UserDefaults.standard.set(true, forKey: PermissionPrimerKeys.primerDone)
            onContinue()
        }

        // Camera
        _ = await AVCaptureDevice.requestAccess(for: .video)
        // Microphone
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        // Photos — add-only, least privilege
        let photo = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
        }
        await DiagnosticsStore.shared.recordEnum(
            .photoAuthStatusAtSave,
            value: PhotosLibraryService.label(for: photo))
        // Notifications
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await DiagnosticsStore.shared.recordEnum(
            .notificationAuthStatus,
            value: granted ? NotificationAuthLabel.granted : .denied)
        // Background App Refresh — system setting, not a runtime
        // permission. We log status; the banner in Settings nudges the
        // user to enable it if needed.
        await DiagnosticsStore.shared.recordEnum(
            .backgroundRefreshStatus,
            value: BackgroundRefreshLabel(rawValue: BackgroundRefreshGuidance.statusLabel) ?? .unknown)
        // Bluetooth is intentionally NOT requested here. The beacon
        // pairing flow in enrollment is the only place we ever ask.
    }
}

enum NotificationAuthLabel: String { case granted, denied }
enum BackgroundRefreshLabel: String { case available, denied, restricted, unknown }
