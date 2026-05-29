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

        // Window-level OCR voting: we collect every per-person OCR result
        // across the entire window, then aggregate at the end. This is the
        // single biggest accuracy win versus per-frame scoring — a stray
        // "23" from the crowd background can't outvote a player who
        // appears in 10+ frames.
        let ocr = JerseyOCR()
        var ocrFrameResults: [JerseyOCR.FrameResult] = []

        // Stage 4: feed every detected person, every frame, into the
        // ByteTracker so we follow ONE persistent subject across the
        // window instead of re-picking the best-looking detection per
        // frame (which flickers between similar-looking players and gives
        // the reframe a jittery, swapping anchor). identityScore per
        // detection is the color+face attribution; ByteTracker aggregates
        // it per track and SubjectTrackSelector picks "the kid".
        let tracker = ByteTracker()
        var analyzedFrames = 0

        while let frame = await iterator.next() {
            if frame.time - lastEmitted < frameInterval { continue }
            lastEmitted = frame.time
            analyzedFrames += 1

            let people: [VNHumanObservation]
            do {
                people = try await vision.detectHumans(in: frame.buffer)
            } catch {
                continue
            }
            guard !people.isEmpty else { continue }
            guard let cgImage = cgImage(from: frame.buffer) else { continue }

            var dets: [ByteDetection] = []
            for person in people {
                guard let personCrop = cropPerson(person, in: cgImage) else {
                    continue
                }

                // OCR every person crop → window-level number vote.
                let frameResult = await ocr.recognize(
                    in: personCrop,
                    targetNumber: enrollment.jerseyNumber)
                ocrFrameResults.append(frameResult)

                let color: Float = upperTorso(of: personCrop).map {
                    scoreJerseyColor(in: $0, target: enrollment.jerseyColorHSV)
                } ?? 0
                let face = await scoreFace(in: personCrop,
                                           target: enrollment.faceEmbedding)
                let cf = combinedColorFace(color: color, face: face)

                dets.append(ByteDetection(frameTime: frame.time,
                                          box: person.boundingBox,
                                          confidence: person.confidence,
                                          identityScore: cf))
            }
            tracker.step(detections: dets)
        }

        // Stage 4: pick the subject track and follow IT. No persistent
        // track → drop the window; the ranker's Tier-3 montage Ken Burns
        // covers it (never-reject contract).
        guard let selection = SubjectTrackSelector(
                identityThreshold: identificationThreshold)
                .select(from: tracker.tracks,
                        analyzedFrameCount: analyzedFrames) else {
            log.info("Stage 2 window \(window.id.uuidString, privacy: .public): no persistent subject track (\(tracker.tracks.count) tracks / \(analyzedFrames) frames) — dropped, ranker Tier 3 will Ken Burns")
            return nil
        }

        let track = selection.track
        // The reframe anchor: the SELECTED track's per-frame boxes — one
        // consistent subject across the whole window.
        let playerBoxes = track.detections.map {
            TimedBox(time: $0.frameTime, box: $0.box)
        }

        // Window-level number score via temporal voting.
        let ocrWindowResult = await ocr.aggregate(
            frameResults: ocrFrameResults,
            targetNumber: enrollment.jerseyNumber)
        let numberScore = ocrWindowResult.matchConfidence
        let meanCF = selection.meanIdentity

        // Identity confidence: trust the jersey number when we have OCR
        // evidence across ≥3 frames; otherwise lean on the selected
        // track's color+face evidence (meanCF already collapses to
        // color-only when no face was detected — see combinedColorFace).
        let identificationConfidence: Float =
            ocrWindowResult.frameCount >= 3
            ? 0.5 * numberScore + 0.5 * meanCF
            : 0.2 * numberScore + 0.8 * meanCF

        // Activity from the SELECTED track's centroid motion — a
        // consistent subject yields meaningful velocity, not best-person
        // swap jitter.
        let centers = track.centroidPath.map(\.point)
        var jointVelocities: [Float] = []
        if centers.count > 1 {
            for i in 1..<centers.count {
                let dx = Float(centers[i].x - centers[i - 1].x)
                let dy = Float(centers[i].y - centers[i - 1].y)
                jointVelocities.append(sqrtf(dx * dx + dy * dy))
            }
        }
        let activityScore = clamp(jointVelocities.reduce(0, +) * 5.0, 0, 1)

        // Composite score — see "Ranking" section in spec
        let composite = 0.40 * identificationConfidence
                      + 0.30 * activityScore
                      + 0.20 * window.audioScore
                      + 0.10 * window.motionScore

        let firstC = centers.first ?? .zero
        let lastC = centers.last ?? .zero
        log.info("Stage 2 window \(window.id.uuidString, privacy: .public): track #\(track.id) identified=\(selection.identified) meanCF=\(meanCF, format: .fixed(precision: 2)) boxes=\(playerBoxes.count) center \(firstC.x, format: .fixed(precision: 2)),\(firstC.y, format: .fixed(precision: 2)) → \(lastC.x, format: .fixed(precision: 2)),\(lastC.y, format: .fixed(precision: 2))")

        return ScoredMoment(id: UUID(),
                            window: window,
                            identificationConfidence: identificationConfidence,
                            activityScore: activityScore,
                            playerBoundingBoxes: playerBoxes,
                            compositeScore: composite)
    }

    // MARK: - Identification scoring

    private func cropPerson(_ person: VNHumanObservation,
                            in image: CGImage) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let bbox = person.boundingBox
        let rect = CGRect(x: bbox.origin.x * imgW,
                          y: (1 - bbox.origin.y - bbox.height) * imgH,
                          width: bbox.width * imgW,
                          height: bbox.height * imgH)
        return image.cropping(to: rect)
    }

    private func upperTorso(of personCrop: CGImage) -> CGImage? {
        let torsoY = personCrop.height / 4
        let torsoH = personCrop.height / 2
        let torsoRect = CGRect(x: 0, y: torsoY,
                               width: personCrop.width, height: torsoH)
        return personCrop.cropping(to: torsoRect)
    }

    /// Per-frame attribution score combining color and face only. Used to
    /// pick the best person in the frame; the jersey number contributes at
    /// the window level via JerseyOCR.aggregate.
    private func combinedColorFace(color: Float, face: Float) -> Float {
        // Renormalize C/F weights from IdentificationWeights so they sum
        // to 1 in the absence of number: color 0.6, face 0.4 by default,
        // collapse to color-only when no face was detected.
        if face == 0 { return color }
        let cf = IdentificationWeights.jerseyColor + IdentificationWeights.face
        let cW = IdentificationWeights.jerseyColor / cf
        let fW = IdentificationWeights.face / cf
        return color * cW + face * fW
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
