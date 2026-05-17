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
import ImageIO
import SwiftUI
import UIKit
import Vision
import os.log

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

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
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        await extractFace(from: cgImage, orientation: orientation)
    }

    private func extractFace(from cgImage: CGImage,
                             orientation: CGImagePropertyOrientation) async {
        do {
            // 1. Find faces. Pass the source orientation so Vision can rotate
            // the bitmap into the expected upright frame — without this, a
            // portrait selfie may be analyzed sideways and confidence tanks.
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: orientation,
                                                options: [:])
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
            //
            // Vision reports boundingBox in the *oriented* coordinate space,
            // so width/height correspond to the upright image dimensions. We
            // compute those from cgImage + orientation rather than raw
            // cgImage.width/height, which can be swapped for portrait shots.
            let (orientedW, orientedH) = orientedExtent(of: cgImage,
                                                        orientation: orientation)
            let faceWidth = face.boundingBox.width * orientedW
            let faceHeight = face.boundingBox.height * orientedH
            log.info("Face: confidence=\(face.confidence) size=\(Int(faceWidth))x\(Int(faceHeight)) image=\(Int(orientedW))x\(Int(orientedH))")

            if faceWidth < 120 || faceHeight < 120 {
                // 120 px is the rough minimum for reliable feature prints.
                // Below that the embedding quality drops a lot.
                faceQualityIssues = [.faceTooSmall]
                return
            }
            // VNDetectFaceRectanglesRequest's confidence is conservative —
            // even crisp, well-lit selfies frequently land in 0.5–0.8.
            // 0.4 keeps obvious garbage out without rejecting real faces.
            if face.confidence < 0.4 {
                faceQualityIssues = [.lowConfidence]
                return
            }

            // 3. Crop face region with a 20% margin from the raw cgImage.
            // We compute the crop in raw bitmap coordinates by un-rotating
            // the bounding box back through the orientation transform.
            let rawRect = boundingBoxInRawPixels(face.boundingBox,
                                                 orientation: orientation,
                                                 cgImage: cgImage)
            let margin: CGFloat = 0.20
            let mw = rawRect.width * margin
            let mh = rawRect.height * margin
            let expandedRect = CGRect(
                x: max(0, rawRect.minX - mw),
                y: max(0, rawRect.minY - mh),
                width: min(CGFloat(cgImage.width) - max(0, rawRect.minX - mw),
                           rawRect.width + 2 * mw),
                height: min(CGFloat(cgImage.height) - max(0, rawRect.minY - mh),
                            rawRect.height + 2 * mh)
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
            let printHandler = VNImageRequestHandler(cgImage: faceCrop,
                                                     orientation: orientation,
                                                     options: [:])
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

    /// Returns the image extent as Vision sees it after applying the source
    /// orientation. For .right / .left orientations width and height swap.
    private func orientedExtent(of cgImage: CGImage,
                                orientation: CGImagePropertyOrientation)
        -> (CGFloat, CGFloat) {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        switch orientation {
        case .right, .rightMirrored, .left, .leftMirrored:
            return (h, w)
        default:
            return (w, h)
        }
    }

    /// Maps a normalized Vision bounding box (origin bottom-left, in the
    /// oriented space) back to raw cgImage pixel coordinates (origin
    /// top-left). Only handles the orientations UIImagePickerController
    /// actually returns for camera-captured stills.
    private func boundingBoxInRawPixels(_ box: CGRect,
                                        orientation: CGImagePropertyOrientation,
                                        cgImage: CGImage) -> CGRect {
        let rawW = CGFloat(cgImage.width)
        let rawH = CGFloat(cgImage.height)
        switch orientation {
        case .up, .upMirrored:
            return CGRect(x: box.minX * rawW,
                          y: (1 - box.maxY) * rawH,
                          width: box.width * rawW,
                          height: box.height * rawH)
        case .down, .downMirrored:
            return CGRect(x: (1 - box.maxX) * rawW,
                          y: box.minY * rawH,
                          width: box.width * rawW,
                          height: box.height * rawH)
        case .right, .rightMirrored:
            // Oriented (W,H) = (rawH, rawW). Box.x maps to rawY, box.y to rawX.
            return CGRect(x: box.minY * rawW,
                          y: box.minX * rawH,
                          width: box.height * rawW,
                          height: box.width * rawH)
        case .left, .leftMirrored:
            return CGRect(x: (1 - box.maxY) * rawW,
                          y: (1 - box.maxX) * rawH,
                          width: box.height * rawW,
                          height: box.width * rawH)
        @unknown default:
            return CGRect(x: box.minX * rawW,
                          y: (1 - box.maxY) * rawH,
                          width: box.width * rawW,
                          height: box.height * rawH)
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
