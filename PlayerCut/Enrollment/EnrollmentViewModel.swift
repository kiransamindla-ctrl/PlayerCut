//
//  EnrollmentViewModel.swift
//  PlayerCut/Enrollment
//
//  Drives the multi-step enrollment wizard:
//    1. Name + jersey number
//    2. Jersey color (sample a swatch via camera or color picker)
//    3. Selfie (face embedding)
//
//  Persists a complete PlayerEnrollment via GameStore. Validates each step
//  before allowing progression.
//

import Foundation
import SwiftUI
import UIKit
import Vision
import os.log

@MainActor
final class EnrollmentViewModel: ObservableObject {

    private let log = Logger(subsystem: "com.playercut.app", category: "Enroll")
    private let store: GameStore

    enum Step: Int, CaseIterable {
        case identity = 0
        case jerseyColor = 1
        case selfie = 2
        case review = 3

        var title: String {
            switch self {
            case .identity: return "Who is this for?"
            case .jerseyColor: return "Jersey color"
            case .selfie: return "Add a photo"
            case .review: return "Review"
            }
        }
    }

    // MARK: - Published state

    @Published var step: Step = .identity
    @Published var name: String = ""
    @Published var jerseyNumber: String = ""
    @Published var sport: Sport = .soccer

    @Published var sampledJerseyImage: UIImage?
    @Published var jerseyColorHistogram: HSVHistogram?

    @Published var selfieImage: UIImage?
    @Published var faceEmbedding: [Float]?
    @Published var faceQualityIssues: [FaceQualityIssue] = []

    @Published var validationError: String?
    @Published var isSaving = false
    @Published var savedPlayerID: UUID?

    enum FaceQualityIssue: String {
        case noFaceFound = "We couldn't find a face. Try better lighting."
        case faceTooSmall = "Move closer — fill more of the frame."
        case multipleFaces = "Make sure only one person is in the photo."
        case lowConfidence = "Photo is too blurry. Try again with steadier hands."
    }

    init(store: GameStore) {
        self.store = store
    }

    // MARK: - Step gates

    var canAdvance: Bool {
        switch step {
        case .identity:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && isValidJersey(jerseyNumber)
        case .jerseyColor:
            return jerseyColorHistogram != nil
        case .selfie:
            return faceEmbedding != nil && faceQualityIssues.isEmpty
        case .review:
            return true
        }
    }

    func advance() {
        guard canAdvance else { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }

    private func isValidJersey(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.count <= 3
            && trimmed.allSatisfy { $0.isNumber }
    }

    // MARK: - Step 2: jersey color

    /// Called when the user takes a photo of the jersey or picks a color
    /// from a swatch. We always extract an HSV histogram from a real image
    /// region (even if the user picks a swatch — we render the swatch into
    /// a small image first) so the matching code doesn't have two paths.
    func captureJerseyColor(from image: UIImage) {
        guard let cgImage = image.cgImage else {
            validationError = "Couldn't process that image."
            return
        }
        // Crop to the central 60% — most jersey photos have noisy edges
        let w = cgImage.width
        let h = cgImage.height
        let crop = CGRect(x: w / 5, y: h / 5,
                          width: 3 * w / 5, height: 3 * h / 5)
        guard let cropped = cgImage.cropping(to: crop) else { return }

        sampledJerseyImage = image
        jerseyColorHistogram = HSVHistogram.from(cropped)
        validationError = nil
    }

    func captureJerseyColor(fromSwatch color: UIColor) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        captureJerseyColor(from: image)
    }

    // MARK: - Step 3: selfie / face embedding

    func captureSelfie(_ image: UIImage) async {
        selfieImage = image
        faceQualityIssues = []
        faceEmbedding = nil

        guard let cgImage = image.cgImage else {
            faceQualityIssues = [.noFaceFound]
            return
        }
        await extractFace(from: cgImage)
    }

    private func extractFace(from cgImage: CGImage) async {
        do {
            // 1. Find faces.
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([faceRequest])
            let faces = faceRequest.results ?? []

            guard !faces.isEmpty else {
                faceQualityIssues = [.noFaceFound]
                return
            }
            if faces.count > 1 {
                faceQualityIssues = [.multipleFaces]
                return
            }
            let face = faces[0]

            // 2. Quality gates.
            let pw = CGFloat(cgImage.width)
            let ph = CGFloat(cgImage.height)
            let faceWidth = face.boundingBox.width * pw
            let faceHeight = face.boundingBox.height * ph

            if faceWidth < 120 || faceHeight < 120 {
                // 120 px is the rough minimum for reliable feature prints.
                // Below that the embedding quality drops a lot.
                faceQualityIssues = [.faceTooSmall]
                return
            }
            if face.confidence < 0.85 {
                faceQualityIssues = [.lowConfidence]
                return
            }

            // 3. Crop face region with a 20% margin (Vision's default crop is
            // tight on the face; including a bit of forehead and chin
            // produces more stable embeddings).
            let margin: CGFloat = 0.20
            let mw = face.boundingBox.width * margin
            let mh = face.boundingBox.height * margin
            let expandedRect = CGRect(
                x: max(0, (face.boundingBox.origin.x - mw) * pw),
                y: max(0, (1 - face.boundingBox.origin.y - face.boundingBox.height - mh) * ph),
                width: min(pw, (face.boundingBox.width + 2 * mw) * pw),
                height: min(ph, (face.boundingBox.height + 2 * mh) * ph)
            )
            guard let faceCrop = cgImage.cropping(to: expandedRect) else {
                faceQualityIssues = [.noFaceFound]
                return
            }

            // 4. Generate embedding via VNGenerateImageFeaturePrintRequest.
            // There is no public face-specific embedding API; using image
            // feature prints on a face crop is the documented workaround
            // and works well enough for "is this the same kid?" matching.
            let printReq = VNGenerateImageFeaturePrintRequest()
            let printHandler = VNImageRequestHandler(cgImage: faceCrop, options: [:])
            try printHandler.perform([printReq])
            guard let observation = printReq.results?.first as? VNFeaturePrintObservation else {
                faceQualityIssues = [.noFaceFound]
                return
            }

            faceEmbedding = observation.featureVector()
            log.info("Face embedding extracted: dim=\(self.faceEmbedding?.count ?? 0)")
        } catch {
            log.error("Face extraction failed: \(error.localizedDescription)")
            faceQualityIssues = [.noFaceFound]
        }
    }

    // MARK: - Save

    func save() async -> Bool {
        guard let histogram = jerseyColorHistogram,
              let embedding = faceEmbedding else {
            validationError = "Missing required data."
            return false
        }
        isSaving = true
        defer { isSaving = false }

        let player = PlayerEnrollment(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            jerseyNumber: jerseyNumber.trimmingCharacters(in: .whitespaces),
            jerseyColorHSV: histogram,
            faceEmbedding: embedding,
            sport: sport,
            createdAt: Date()
        )
        do {
            try await store.upsert(player)
            savedPlayerID = player.id
            await DiagnosticsStore.shared.recordDailyEvent(.enrollmentCompleted)
            return true
        } catch {
            validationError = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }
}
