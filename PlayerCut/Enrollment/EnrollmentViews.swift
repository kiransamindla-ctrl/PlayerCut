//
//  EnrollmentViews.swift
//  PlayerCut/Enrollment
//
//  SwiftUI for the enrollment wizard. Designed to be drop-in: present
//  EnrollmentRootView from anywhere in the app and it handles the whole flow.
//
//  Camera capture uses UIImagePickerController via UIViewControllerRepresentable
//  rather than PHPickerViewController so we get live capture, not just
//  library pick. Live capture is critical because we want a fresh photo
//  for each enrollment, not whatever's in the user's library.
//

import SwiftUI
import UIKit

// MARK: - Root

struct EnrollmentRootView: View {
    @StateObject var vm: EnrollmentViewModel
    var onComplete: (UUID) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()

                VStack(spacing: 0) {
                    EnrollmentProgressBar(currentStep: vm.step)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.step.title.uppercased())
                            .font(.pcTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .tracking(1.5)
                            .accessibilityIdentifier("enrollment-step-title")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    Group {
                        switch vm.step {
                        case .identity:
                            IdentityStepView(vm: vm)
                        case .jerseyColor:
                            JerseyColorStepView(vm: vm)
                        case .selfie:
                            SelfieStepView(vm: vm)
                        case .reelLength:
                            ReelLengthStepView(vm: vm)
                        case .review:
                            ReviewStepView(vm: vm)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    BottomBar(vm: vm,
                              onComplete: onComplete,
                              onCancel: onCancel)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgDark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

// MARK: - Progress bar

struct EnrollmentProgressBar: View {
    let currentStep: EnrollmentViewModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EnrollmentViewModel.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue
                          ? Theme.accent
                          : Theme.textSecondary.opacity(0.3))
                    .frame(height: 8)
            }
        }
    }
}

// MARK: - Step 1: identity

struct IdentityStepView: View {
    @ObservedObject var vm: EnrollmentViewModel

    var body: some View {
        Form {
            Section {
                TextField("Player name", text: $vm.name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
            } header: {
                Text("Name")
            } footer: {
                Text("Just a first name is fine.")
            }

            Section {
                TextField("23", text: $vm.jerseyNumber)
                    .keyboardType(.numberPad)
                    .onChange(of: vm.jerseyNumber) { _, newValue in
                        // Strip non-digits and cap at 3
                        let cleaned = newValue.filter { $0.isNumber }
                        if cleaned != newValue {
                            vm.jerseyNumber = String(cleaned.prefix(3))
                        } else if cleaned.count > 3 {
                            vm.jerseyNumber = String(cleaned.prefix(3))
                        }
                    }
            } header: {
                Text("Jersey number")
            } footer: {
                Text("If they don't have a number, you'll be able to identify them by color and face only.")
            }

            Section("Sport") {
                Picker("Sport", selection: $vm.sport) {
                    Text("Soccer").tag(Sport.soccer)
                    Text("Basketball").tag(Sport.basketball)
                    Text("Pickleball").tag(Sport.pickleball)
                    Text("Lacrosse").tag(Sport.lacrosse)
                    Text("Football").tag(Sport.footballAmerican)
                }
                .pickerStyle(.menu)
            }
        }
    }
}

// MARK: - Step 2: jersey color

struct JerseyColorStepView: View {
    @ObservedObject var vm: EnrollmentViewModel
    @State private var showingCamera = false
    @State private var showingPicker = false
    @State private var pickedColor: Color = .blue

    var body: some View {
        VStack(spacing: 24) {
            Text("Take a photo of the jersey, or pick the closest color.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if let image = vm.sampledJerseyImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green, lineWidth: 3)
                    )
                    .padding(.horizontal)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 220)
                    .overlay(
                        VStack {
                            Image(systemName: "tshirt").font(.system(size: 56))
                            Text("No jersey sampled yet")
                                .foregroundStyle(.secondary)
                        }
                    )
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Button {
                    showingCamera = true
                } label: {
                    Label("Take photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showingPicker = true
                } label: {
                    Label("Pick color", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
        .sheet(isPresented: $showingCamera) {
            ImageCaptureView(sourceType: .camera) { image in
                vm.captureJerseyColor(from: image)
            }
        }
        .sheet(isPresented: $showingPicker) {
            VStack(spacing: 24) {
                Text("Pick the closest color")
                    .font(.headline)
                ColorPicker("Jersey color",
                            selection: $pickedColor,
                            supportsOpacity: false)
                    .padding()
                Button("Use this color") {
                    vm.captureJerseyColor(fromSwatch: UIColor(pickedColor))
                    showingPicker = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding()
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Step 3: selfie

struct SelfieStepView: View {
    @ObservedObject var vm: EnrollmentViewModel
    @State private var showingCamera = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Take a clear photo of \(vm.name.isEmpty ? "the player" : vm.name).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ZStack {
                if let image = vm.selfieImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(vm.faceEmbedding != nil
                                        ? Color.green
                                        : Color.orange,
                                        lineWidth: 3)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 280)
                        .overlay(
                            VStack {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 56))
                                Text("No photo yet").foregroundStyle(.secondary)
                            }
                        )
                }
            }
            .padding(.horizontal)

            if !vm.faceQualityIssues.isEmpty {
                ForEach(vm.faceQualityIssues, id: \.rawValue) { issue in
                    Label(issue.rawValue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                        .padding(.horizontal)
                }
            }

            Button {
                showingCamera = true
            } label: {
                Label(vm.selfieImage == nil ? "Take photo" : "Retake",
                      systemImage: "camera")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
        .sheet(isPresented: $showingCamera) {
            ImageCaptureView(sourceType: .camera) { image in
                Task { await vm.captureSelfie(image) }
            }
        }
    }
}

// MARK: - Step 4: reel length

struct ReelLengthStepView: View {
    @ObservedObject var vm: EnrollmentViewModel

    var body: some View {
        Form {
            Section {
                Picker("Reel length", selection: $vm.reelLengthPreference) {
                    ForEach(ReelLength.allCases, id: \.self) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Preferred reel length")
            } footer: {
                Text("Longer reels capture more of the game but take longer to process.")
            }
        }
    }
}

// MARK: - Step 5: review

struct ReviewStepView: View {
    @ObservedObject var vm: EnrollmentViewModel

    var body: some View {
        Form {
            Section("Player") {
                LabeledContent("Name", value: vm.name)
                LabeledContent("Jersey #", value: vm.jerseyNumber)
                LabeledContent("Sport", value: vm.sport.rawValue.capitalized)
                LabeledContent("Reel length", value: vm.reelLengthPreference.displayName)
            }

            Section("Identification signals") {
                HStack {
                    if let img = vm.sampledJerseyImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Jersey color sampled")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack {
                    if let img = vm.selfieImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                    }
                    Text("Face captured")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("This data stays on your phone. We never upload your child's photo or face data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var vm: EnrollmentViewModel
    let onComplete: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    Haptic.tap()
                    if vm.step == .identity { onCancel() } else { vm.goBack() }
                } label: {
                    Text(vm.step == .identity ? "CANCEL" : "BACK")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            if vm.step == .review {
                PCPillButton(title: "Done",
                             systemImage: vm.isSaving ? nil : "checkmark.circle.fill",
                             tint: Theme.primary,
                             height: 64) {
                    Task {
                        if await vm.save(), let id = vm.savedPlayerID {
                            Haptic.success()
                            onComplete(id)
                        }
                    }
                }
                .disabled(vm.isSaving)
                .opacity(vm.isSaving ? 0.5 : 1)
            } else {
                PCPillButton(title: "Next",
                             systemImage: "arrow.right.circle.fill",
                             tint: vm.canAdvance ? Theme.primary : Theme.textSecondary,
                             height: 64) {
                    vm.advance()
                }
                .disabled(!vm.canAdvance)
                .opacity(vm.canAdvance ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Theme.bgDark)
    }
}

// MARK: - UIImagePickerController bridge

struct ImageCaptureView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = true
        picker.cameraDevice = .front
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject,
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let parent: ImageCaptureView
        init(_ parent: ImageCaptureView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] as? UIImage)
                ?? (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
            if let image { parent.onImage(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
