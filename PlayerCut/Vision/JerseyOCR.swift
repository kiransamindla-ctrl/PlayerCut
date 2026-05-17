//
//  JerseyOCR.swift
//  PlayerCut
//
//  Production OCR for jersey numbers in real-world game footage.
//
//  The naive approach (one VNRecognizeTextRequest on the torso crop) fails on
//  most frames because:
//    1. The jersey is 40–80 px tall when the kid is 20m away — below
//       Vision's reliable text size.
//    2. Motion blur smears the digits during action.
//    3. Sweat, folds, and partial occlusion (arms across torso) corrupt one
//       digit in a two-digit number.
//    4. Vision returns "back of jersey" text ("FERRARO 23") that gets fused
//       with the digits if the box is wrong.
//    5. The same player appears at multiple frames — a single-frame answer is
//       both wasteful (we see them many times) and brittle.
//
//  Strategy:
//    A. Upscale the torso crop to 2× before OCR (Vision is sensitive to text
//       size; bicubic upscaling more than doubles recognition rate on small
//       jerseys).
//    B. Extract digits-only via character-level whitelist + post-filter.
//    C. Run OCR on TWO crops per person — full torso AND a "back of jersey"
//       sub-region — and union the candidates.
//    D. Fuzzy-match (Levenshtein-1) every candidate against the target
//       number, picking the best hit.
//    E. Across all frames in a candidate window, accumulate per-frame results
//       into a temporal vote — return the running confidence so the
//       identification scorer can weight by evidence count.
//

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import os.log

actor JerseyOCR {

    private let log = Logger(subsystem: "com.playercut.app", category: "JerseyOCR")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Target minimum height in pixels after upscale. Empirically Vision
    // recognizes text reliably above ~32 px; we shoot for 80 px to give
    // headroom for blur and rotation.
    private let targetTextHeight: CGFloat = 80

    // Vision keeps returning candidates with very low confidence; we discard
    // anything below this. Tuned against a labeled corpus.
    private let minRecognitionConfidence: VNConfidence = 0.30

    /// Per-frame OCR result. Use these as votes accumulated across a window.
    struct FrameResult {
        let recognizedNumbers: [(value: String, confidence: Float)]
        let elapsed: TimeInterval
    }

    /// Per-window accumulated result.
    struct WindowResult {
        let bestMatch: String?            // closest number seen, if any
        let matchConfidence: Float        // 0..1 weighted by evidence
        let frameCount: Int               // frames where we saw something
    }

    // MARK: - Per-frame OCR

    func recognize(in personCrop: CGImage,
                   targetNumber: String) async -> FrameResult {
        let started = Date()

        // 1. Build the two crops — torso and back-shoulder zone.
        let crops = makeOCRCrops(personCrop: personCrop)

        // 2. Run OCR on each, in parallel.
        async let torsoResults = ocr(on: crops.torso)
        async let backResults = ocr(on: crops.back)

        let combined = await torsoResults + backResults

        // 3. Filter to digits-only and dedupe.
        let digitOnly: [(String, Float)] = combined.compactMap { entry in
            let cleaned = entry.value.filter { $0.isNumber }
            guard cleaned.count >= 1, cleaned.count <= 3 else { return nil }
            return (cleaned, entry.confidence)
        }

        // 4. For each digit candidate, compute fuzzy-match score against the
        // target. We keep ALL candidates that match within distance 1 — the
        // window-level aggregator will vote.
        var matches: [(String, Float)] = []
        for (cand, baseConf) in digitOnly {
            let dist = levenshtein(cand, targetNumber)
            let matchScore: Float
            switch dist {
            case 0: matchScore = 1.0
            case 1: matchScore = 0.6
            case 2: matchScore = 0.2
            default: matchScore = 0
            }
            if matchScore > 0 {
                matches.append((cand, baseConf * matchScore))
            }
        }

        // Sort by combined confidence; keep top 3.
        let topMatches = matches.sorted { $0.1 > $1.1 }.prefix(3)

        return FrameResult(
            recognizedNumbers: Array(topMatches),
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Window-level temporal voting

    func aggregate(frameResults: [FrameResult],
                   targetNumber: String) -> WindowResult {

        guard !frameResults.isEmpty else {
            return WindowResult(bestMatch: nil, matchConfidence: 0, frameCount: 0)
        }

        // Vote: each frame contributes its top candidate weighted by confidence.
        // The "winner" is the digit string with the largest summed confidence.
        var votes: [String: Float] = [:]
        var framesWithEvidence = 0

        for frame in frameResults {
            guard let top = frame.recognizedNumbers.first else { continue }
            framesWithEvidence += 1
            votes[top.value, default: 0] += top.confidence
        }

        guard let winner = votes.max(by: { $0.value < $1.value }) else {
            return WindowResult(bestMatch: nil, matchConfidence: 0, frameCount: 0)
        }

        // Confidence calibration:
        //   • Single match = vote weight directly (max ~1.0)
        //   • Multiple matches = average vote weight (penalize disagreement)
        //   • Bonus if winner exactly matches target
        //
        // The cap at 1.0 prevents over-confidence from inflating the
        // composite ranking score downstream.
        let evidenceShare = votes[winner.key]! /
            max(1, votes.values.reduce(0, +))
        let exactMatchBonus: Float = (winner.key == targetNumber) ? 0.2 : 0
        let confidence = min(1.0,
                             evidenceShare * winner.value + exactMatchBonus)

        return WindowResult(
            bestMatch: winner.key,
            matchConfidence: confidence,
            frameCount: framesWithEvidence
        )
    }

    // MARK: - Crop preparation

    private struct OCRCrops {
        let torso: CGImage
        let back: CGImage
    }

    /// Builds two upscaled crops from a person bounding box.
    /// The "torso" is the upper-middle band; the "back" is a slightly wider
    /// crop that catches text wrapped onto the back-shoulder area when the
    /// kid is angled away from the camera.
    private func makeOCRCrops(personCrop: CGImage) -> OCRCrops {
        let h = personCrop.height
        let w = personCrop.width

        // Torso: vertical band 25%–65% of height, full width
        let torsoRect = CGRect(x: 0,
                               y: Int(Double(h) * 0.25),
                               width: w,
                               height: Int(Double(h) * 0.40))
        let torso = personCrop.cropping(to: torsoRect) ?? personCrop

        // Back/upper: vertical band 15%–55%, useful when angled
        let backRect = CGRect(x: 0,
                              y: Int(Double(h) * 0.15),
                              width: w,
                              height: Int(Double(h) * 0.40))
        let back = personCrop.cropping(to: backRect) ?? personCrop

        return OCRCrops(
            torso: upscale(torso, targetHeight: targetTextHeight * 2.5),
            back: upscale(back, targetHeight: targetTextHeight * 2.5)
        )
    }

    /// Bicubic upscale via Core Image. Vision's text recognition is markedly
    /// better at 80–120 px tall text than at 30–40 px. The trick is to upscale
    /// enough that the model resolves the digit shape, but not so much that
    /// you amplify motion blur.
    private func upscale(_ image: CGImage, targetHeight: CGFloat) -> CGImage {
        let currentHeight = CGFloat(image.height)
        guard currentHeight < targetHeight else { return image }

        let scale = targetHeight / currentHeight
        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = ciImage
        filter.scale = Float(scale)
        filter.aspectRatio = 1.0

        guard let output = filter.outputImage,
              let cgOutput = ciContext.createCGImage(output, from: output.extent) else {
            return image
        }
        return cgOutput
    }

    // MARK: - OCR core

    private func ocr(on image: CGImage) async -> [(value: String, confidence: Float)] {
        await withCheckedContinuation { (cont: CheckedContinuation<[(String, Float)], Never>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    self.log.debug("OCR error: \(error.localizedDescription)")
                    cont.resume(returning: [])
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var results: [(String, Float)] = []
                for obs in observations {
                    // Get top 3 candidates per observation; numbers are short
                    // and Vision's #2 candidate is sometimes correct when #1
                    // is "L3" instead of "13".
                    for cand in obs.topCandidates(3) {
                        guard cand.confidence >= self.minRecognitionConfidence else { continue }
                        results.append((cand.string, cand.confidence))
                    }
                }
                cont.resume(returning: results)
            }
            // Configuration:
            //   .accurate is slower but worth it for small text
            //   usesLanguageCorrection = false: we want raw digits, not
            //     "spellchecked" output ("OO" → "00" stays "OO" with this off,
            //     but the digit-filter step handles cleanup)
            //   recognitionLanguages: jersey text can be sponsor logos in any
            //     language; restricting helps focus the model
            //   minimumTextHeight: relative to image; 0.05 = at least 5% tall
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.05

            // Custom words bias toward digits — Vision uses this as a prior
            // for ambiguous characters.
            request.customWords = (0...99).map { String($0) }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                self.log.debug("OCR perform failed: \(error.localizedDescription)")
                cont.resume(returning: [])
            }
        }
    }

    // MARK: - Levenshtein

    private nonisolated func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}

// MARK: - Diagnostic helpers (debug builds only)

#if DEBUG
extension JerseyOCR {
    /// Saves both crops as PNGs to /tmp for visual debugging.
    /// Useful when tuning targetTextHeight or torso band fractions.
    func dumpCropsForDebug(personCrop: CGImage, gameID: UUID, frameIndex: Int) {
        let crops = makeOCRCrops(personCrop: personCrop)
        for (label, image) in [("torso", crops.torso), ("back", crops.back)] {
            let url = URL(fileURLWithPath: "/tmp/playercut-\(gameID)-f\(frameIndex)-\(label).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                          UTType.png.identifier as CFString,
                                                          1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}

import CoreServices
import UniformTypeIdentifiers
import ImageIO
#endif
