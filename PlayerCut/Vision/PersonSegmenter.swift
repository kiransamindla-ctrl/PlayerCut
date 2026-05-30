//
//  PersonSegmenter.swift
//  PlayerCut/Vision
//
//  Apple-native person segmentation (VNGeneratePersonSegmentationRequest,
//  iOS 15+). Driven by `ReelSettings.backgroundMode` — the MetalPetal
//  compositor uses the returned mask buffer to composite the kid over a
//  blurred-background plate (Cutout) or to apply a stronger grade only
//  inside the mask (Pop). One Vision request per frame; the request is
//  cached per-instance so the Vision pipeline doesn't re-allocate.
//
//  Caching: callers may pass a previous-frame mask + box; when the
//  subject box hasn't moved much the cache hit avoids the request.
//  Sim caveat: on the synthetic SampleVideoFactory source (no real
//  human in frame) Vision returns an all-zero mask. Tests assert the
//  request RUNS and returns a correctly-shaped CVPixelBuffer; mask
//  non-zero proof is device-only.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Vision
import os.log

@available(iOS 15.0, *)
final class PersonSegmenter {

    private let log = Logger(subsystem: "com.playercut.app",
                             category: "PersonSegmenter")
    private let request: VNGeneratePersonSegmentationRequest

    /// `.accurate` (offline, slow, best edges) by default. Compose runs in
    /// the background so the budget is fine; live preview should pick
    /// `.balanced` or `.fast`.
    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel = .accurate) {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = quality
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.request = r
    }

    /// Runs the request on `pixelBuffer` and returns the mask buffer
    /// (single-channel 8-bit, same orientation as the input). nil when
    /// the request fails or produces no observation — caller treats it
    /// as "no segmentation this frame, fall through to normal compositor".
    func mask(for pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.warning("PersonSegmenter.perform failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first
            as? VNPixelBufferObservation else {
            return nil
        }
        return observation.pixelBuffer
    }

    /// Convenience: run on a CMSampleBuffer (what AVAssetReader hands us).
    func mask(for sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return mask(for: pb)
    }
}
