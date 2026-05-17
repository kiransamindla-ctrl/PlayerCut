//
//  VisionPipeline.swift
//  PlayerCut/Performance
//
//  Performance-tuned wrapper around Vision requests for video-frame analysis.
//
//  Two key wins over naïve VNImageRequestHandler-per-frame:
//
//   1. VNSequenceRequestHandler keeps internal state across calls. For
//      requests that benefit from temporal context (optical flow, person
//      tracking), this is the difference between accurate and useless.
//      Even for stateless requests, the sequence handler avoids re-reading
//      the source format each call.
//
//   2. Request objects are reusable. Creating a VNDetectHumanRectanglesRequest
//      is cheap individually but adds up across 24,000 frames. Pool them
//      per analysis worker.
//
//  Additionally:
//
//   3. usesCPUOnly = false (default) routes to Neural Engine on A-series
//      chips. Setting it to true is a 5–10× slowdown — never set it to
//      true unless you're debugging.
//
//   4. preferBackgroundProcessing (iOS 14+) tells Vision to throttle when
//      the user is interactive. Set this when running in the foreground
//      runner so the UI stays smooth.
//
//   5. Avoid VNRequest.maximumObservations unless you need to. The default
//      caps work fine and Vision can early-exit cheaper.
//

import Vision
import CoreVideo
import Foundation
import os.log

actor VisionPipeline {

    private let log = Logger(subsystem: "com.playercut.app", category: "VisionPipe")

    // One sequence handler per analysis pass. Reusing it across frames is
    // what makes optical flow and person tracking actually work.
    private let sequenceHandler = VNSequenceRequestHandler()

    // Pre-built requests. Vision allows a request to be performed against
    // multiple images in sequence as long as you don't mutate its
    // configuration between calls.
    private let humanDetectRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        r.preferBackgroundProcessing = true
        r.revision = VNDetectHumanRectanglesRequestRevision2
        return r
    }()

    private let textRequest: VNRecognizeTextRequest = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = false
        r.recognitionLanguages = ["en-US"]
        r.minimumTextHeight = 0.05
        r.preferBackgroundProcessing = true
        r.customWords = (0...99).map { String($0) }
        return r
    }()

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.preferBackgroundProcessing = true
        return r
    }()

    private let featurePrintRequest: VNGenerateObjectFeaturePrintRequest = {
        let r = VNGenerateObjectFeaturePrintRequest()
        r.preferBackgroundProcessing = true
        return r
    }()

    private let bodyPoseRequest: VNDetectHumanBodyPoseRequest = {
        let r = VNDetectHumanBodyPoseRequest()
        r.preferBackgroundProcessing = true
        return r
    }()

    // MARK: - Person detection (sequence handler — temporal coherence helps)

    func detectHumans(in pixelBuffer: CVPixelBuffer) throws -> [VNHumanObservation] {
        try sequenceHandler.perform([humanDetectRequest], on: pixelBuffer)
        return humanDetectRequest.results ?? []
    }

    // MARK: - Text recognition (image handler — sequence buys nothing here)

    func recognizeText(in cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([textRequest])
        return textRequest.results ?? []
    }

    // MARK: - Face detection + embedding (two-stage)

    /// Returns the feature print observation for the first face found, or nil
    /// if no face was detected at sufficient resolution. Combining the two
    /// requests in one method lets us short-circuit the second when the
    /// first finds nothing — saves about 4ms per call.
    func faceFeaturePrint(in cgImage: CGImage,
                          minimumFaceSize: CGFloat = 24) throws
        -> VNFeaturePrintObservation? {

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest])
        guard let face = faceRequest.results?.first else { return nil }

        let pw = CGFloat(cgImage.width)
        let ph = CGFloat(cgImage.height)
        let faceRect = CGRect(
            x: face.boundingBox.origin.x * pw,
            y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * ph,
            width: face.boundingBox.width * pw,
            height: face.boundingBox.height * ph
        )
        guard faceRect.width >= minimumFaceSize,
              faceRect.height >= minimumFaceSize,
              let faceCrop = cgImage.cropping(to: faceRect) else { return nil }

        let printHandler = VNImageRequestHandler(cgImage: faceCrop, options: [:])
        try printHandler.perform([featurePrintRequest])
        return featurePrintRequest.results?.first as? VNFeaturePrintObservation
    }

    // MARK: - Body pose

    func detectPose(in cgImage: CGImage) throws -> [VNHumanBodyPoseObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([bodyPoseRequest])
        return bodyPoseRequest.results ?? []
    }
}

// MARK: - Memory pressure handling

import Dispatch

/// Watches for system memory warnings and notifies registered handlers so
/// the pipeline can flush pools and skip non-essential work. The pipeline
/// orchestrator should pause batch work when fired and resume after a
/// short cooldown.
final class MemoryPressureMonitor: @unchecked Sendable {

    static let shared = MemoryPressureMonitor()
    private let source: DispatchSourceMemoryPressure
    private let queue = DispatchQueue(label: "playercut.mempressure",
                                      qos: .utility)
    private var handlers: [(DispatchSource.MemoryPressureEvent) -> Void] = []
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.playercut.app", category: "MemPressure")

    private init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            self.log.warning("Memory pressure: \(String(describing: event))")
            self.lock.lock()
            let snapshot = self.handlers
            self.lock.unlock()
            for h in snapshot { h(event) }
        }
        source.resume()
    }

    func addHandler(_ handler: @escaping (DispatchSource.MemoryPressureEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }
}
