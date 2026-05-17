//
//  Stage2PlayerLocalizer.swift
//  PlayerCut
//
//  Stage 2: For each Stage-1 candidate window, runs person detection +
//  jersey OCR + jersey color + face embedding + pose. Identifies the enrolled
//  player, scores activity, and produces ScoredMoment objects.
//

import AVFoundation
import Vision
import CoreImage
import Foundation
import os.log

actor Stage2PlayerLocalizer {

    private let log = Logger(subsystem: "com.playercut.app", category: "Stage2")

    private let analysisFPS: Double = 6.0   // 6 fps inside each candidate window
    private let identificationThreshold: Float = 0.55

    // Composite weights — see ranking notes below.
    private struct IdentificationWeights {
        static let jerseyNumber: Float = 0.50
        static let jerseyColor: Float  = 0.30
        static let face: Float         = 0.20
    }

    private let vision = VisionPipeline()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Pause-until set by the orchestrator on critical memory pressure.
    private var pauseUntil: Date?

    // MARK: - Memory pressure

    func pause(forSeconds seconds: TimeInterval) {
        pauseUntil = Date().addingTimeInterval(seconds)
        log.warning("Stage 2 paused for \(seconds, format: .fixed(precision: 0))s")
    }

    /// No pixel-buffer pools held here — FrameIterator's reader owns its
    /// buffers and recycles them as it advances. Kept as a no-op for
    /// symmetry with Stage 1 so the orchestrator can flush both uniformly.
    func flushPools() { /* intentionally empty */ }

    func localize(in game: GameSession,
                  candidates: [CandidateWindow],
                  enrollment: PlayerEnrollment) async throws -> Stage2Result {
        let start = Date()
        var moments: [ScoredMoment] = []

        for window in candidates {
            try await waitIfPaused()
            do {
                if let moment = try await processWindow(window,
                                                        videoURL: game.rawVideoURL,
                                                        enrollment: enrollment) {
                    moments.append(moment)
                }
            } catch {
                log.error("Window \(window.id.uuidString) failed: \(error.localizedDescription)")
                // continue — one bad window shouldn't kill the reel
            }
        }

        log.info("Stage 2 produced \(moments.count) identified moments")
        return Stage2Result(moments: moments,
                            processingDuration: Date().timeIntervalSince(start))
    }

    private func waitIfPaused() async throws {
        guard let until = pauseUntil, until > Date() else { return }
        let delay = until.timeIntervalSinceNow
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }

    // MARK: - Per-window processing

    private func processWindow(_ window: CandidateWindow,
                               videoURL: URL,
                               enrollment: PlayerEnrollment) async throws
        -> ScoredMoment? {

        // Stream the window's frames at 1280×720 via AVAssetReader rather
        // than seek-per-frame with AVAssetImageGenerator.
        let iterator = FrameIterator(url: videoURL)
        try await iterator.seek(to: window.startTime,
                                endTime: window.endTime,
                                outputSize: CGSize(width: 1280, height: 720))
        defer { Task { await iterator.cancel() } }

        let frameInterval = 1.0 / analysisFPS
        var lastEmitted: Double = -.infinity

        var bestPlayerScores: [Float] = []
        var jointVelocities: [Float] = []
        var playerBoxes: [TimedBox] = []
        var lastBoxCenter: CGPoint?

        while let frame = await iterator.next() {
            if frame.time - lastEmitted < frameInterval { continue }
            lastEmitted = frame.time

            // 1. Detect humans via the shared VisionPipeline actor.
            let people: [VNHumanObservation]
            do {
                people = try await vision.detectHumans(in: frame.buffer)
            } catch {
                continue
            }
            guard !people.isEmpty else { continue }

            // Only realize a CGImage when we have humans to score —
            // skips the convert cost on empty frames.
            guard let cgImage = cgImage(from: frame.buffer) else { continue }

            // 2. Score each detected person against enrollment.
            var bestScore: Float = 0
            var bestBox: CGRect?

            for person in people {
                let score = try await scoreCandidate(person: person,
                                                     in: cgImage,
                                                     enrollment: enrollment)
                if score > bestScore {
                    bestScore = score
                    bestBox = person.boundingBox
                }
            }

            if bestScore >= identificationThreshold, let box = bestBox {
                bestPlayerScores.append(bestScore)
                playerBoxes.append(TimedBox(time: frame.time, box: box))

                let center = CGPoint(x: box.midX, y: box.midY)
                if let last = lastBoxCenter {
                    let dx = Float(center.x - last.x)
                    let dy = Float(center.y - last.y)
                    jointVelocities.append(sqrtf(dx * dx + dy * dy))
                }
                lastBoxCenter = center
            }
        }

        // Need at least 3 confirmed sightings to count
        guard bestPlayerScores.count >= 3 else { return nil }

        let identificationConfidence = bestPlayerScores.reduce(0, +)
            / Float(bestPlayerScores.count)
        let activityScore = clamp(jointVelocities.reduce(0, +) * 5.0, 0, 1)

        // Composite score — see "Ranking" section in spec
        let composite = 0.40 * identificationConfidence
                      + 0.30 * activityScore
                      + 0.20 * window.audioScore
                      + 0.10 * window.motionScore

        return ScoredMoment(id: UUID(),
                            window: window,
                            identificationConfidence: identificationConfidence,
                            activityScore: activityScore,
                            playerBoundingBoxes: playerBoxes,
                            compositeScore: composite)
    }

    // MARK: - Identification scoring

    private func scoreCandidate(person: VNHumanObservation,
                                in image: CGImage,
                                enrollment: PlayerEnrollment) async throws -> Float {

        // Crop to person's bounding box (Vision uses bottom-left origin, normalized)
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let bbox = person.boundingBox
        let rect = CGRect(x: bbox.origin.x * imgW,
                          y: (1 - bbox.origin.y - bbox.height) * imgH,
                          width: bbox.width * imgW,
                          height: bbox.height * imgH)
        guard let personCrop = image.cropping(to: rect) else { return 0 }

        // Torso = upper-middle band of the bounding box
        let torsoY = personCrop.height / 4
        let torsoH = personCrop.height / 2
        let torsoRect = CGRect(x: 0, y: torsoY,
                               width: personCrop.width, height: torsoH)
        let torsoCrop = personCrop.cropping(to: torsoRect)

        // Run sub-scores in parallel where possible
        async let numberScore: Float = {
            guard let torso = torsoCrop else { return 0 }
            return await self.scoreJerseyNumber(in: torso,
                                                target: enrollment.jerseyNumber)
        }()

        async let colorScore: Float = {
            guard let torso = torsoCrop else { return 0 }
            return await self.scoreJerseyColor(in: torso,
                                               target: enrollment.jerseyColorHSV)
        }()

        async let faceScore: Float = scoreFace(in: personCrop,
                                               target: enrollment.faceEmbedding)

        let n = await numberScore
        let c = await colorScore
        let f = await faceScore

        // Face is unreliable at distance; if we couldn't extract one (f == 0),
        // redistribute its weight proportionally to number and color.
        if f == 0 {
            let nWeight = IdentificationWeights.jerseyNumber
                / (IdentificationWeights.jerseyNumber + IdentificationWeights.jerseyColor)
            let cWeight = IdentificationWeights.jerseyColor
                / (IdentificationWeights.jerseyNumber + IdentificationWeights.jerseyColor)
            return n * nWeight + c * cWeight
        }
        return n * IdentificationWeights.jerseyNumber
             + c * IdentificationWeights.jerseyColor
             + f * IdentificationWeights.face
    }

    // Jersey number via VisionPipeline's reused text request + fuzzy match.
    private func scoreJerseyNumber(in torso: CGImage, target: String) async -> Float {
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try await vision.recognizeText(in: torso)
        } catch {
            return 0
        }
        var bestScore: Float = 0
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let cleaned = candidate.string.filter { $0.isNumber || $0 == "0" }
            if cleaned.isEmpty { continue }
            let distance = levenshtein(cleaned, target)
            // Distance 0 → 1.0; distance 1 → 0.6; distance 2 → 0.2; further → 0
            let score: Float
            switch distance {
            case 0: score = 1.0
            case 1: score = 0.6
            case 2: score = 0.2
            default: score = 0
            }
            bestScore = max(bestScore, score)
        }
        return bestScore
    }

    private func scoreJerseyColor(in torso: CGImage,
                                  target: HSVHistogram) -> Float {
        let hist = HSVHistogram.from(torso)
        let chi = hist.chiSquared(to: target)
        // Map chi (0 = identical, ~1 = unrelated) into a 0..1 score
        return max(0, 1 - chi)
    }

    private func scoreFace(in personCrop: CGImage,
                           target: [Float]) async -> Float {
        let observation: VNFeaturePrintObservation?
        do {
            observation = try await vision.faceFeaturePrint(in: personCrop,
                                                            minimumFaceSize: 24)
        } catch {
            return 0
        }
        guard let observation else { return 0 }

        let candidate = observation.featureVector()
        guard candidate.count == target.count, !candidate.isEmpty else { return 0 }
        return cosineSimilarity(candidate, target)
    }

    // MARK: - Buffer → CGImage

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Helpers

    private func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        min(hi, max(lo, x))
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return max(0, dot / (sqrtf(na) * sqrtf(nb)))
    }

}

// MARK: - Featureprint adapter

extension VNFeaturePrintObservation {
    func featureVector() -> [Float] {
        let count = elementCount
        var floats = [Float](repeating: 0, count: count)
        let data = self.data
        data.withUnsafeBytes { raw in
            if elementType == .float {
                let ptr = raw.bindMemory(to: Float.self)
                for i in 0..<count { floats[i] = ptr[i] }
            }
        }
        return floats
    }
}

// MARK: - HSV histogram extractor

extension HSVHistogram {
    static func from(_ image: CGImage) -> HSVHistogram {
        // Downsample for speed
        let size = CGSize(width: 64, height: 64)
        let bitsPerComponent = 8
        let bytesPerRow = Int(size.width) * 4
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        let ctx = CGContext(data: &bytes,
                            width: Int(size.width),
                            height: Int(size.height),
                            bitsPerComponent: bitsPerComponent,
                            bytesPerRow: bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(origin: .zero, size: size))

        var bins = [Float](repeating: 0, count: 32 * 8)
        let pixelCount = Int(size.width * size.height)
        for i in 0..<pixelCount {
            let r = Float(bytes[i * 4]) / 255.0
            let g = Float(bytes[i * 4 + 1]) / 255.0
            let b = Float(bytes[i * 4 + 2]) / 255.0
            let (h, s, _) = rgbToHSV(r: r, g: g, b: b)
            let hBin = min(31, Int(h * 32))
            let sBin = min(7, Int(s * 8))
            bins[hBin * 8 + sBin] += 1
        }
        let total = bins.reduce(0, +)
        if total > 0 {
            for i in 0..<bins.count { bins[i] /= total }
        }
        return HSVHistogram(bins: bins)
    }

    private static func rgbToHSV(r: Float, g: Float, b: Float)
        -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h: Float = 0
        if delta > 0 {
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC == 0 ? 0 : delta / maxC
        return (h, s, maxC)
    }
}
