//
//  FrameIterator.swift
//  PlayerCut/Performance
//
//  Streams frames from a recorded video using AVAssetReader. This is 5–10×
//  faster than AVAssetImageGenerator for sequential access patterns.
//
//  Use AVAssetReader when:
//   - Reading frames sequentially in time order (Stage 1's optical flow loop)
//   - Reading many frames from the same time range
//
//  Use AVAssetImageGenerator when:
//   - Reading scattered frames across the video (Stage 2's per-window
//     access — but even there, batched access by window is faster with
//     reader if windows don't overlap, which they don't post-Stage-1)
//
//  AVAssetImageGenerator forces a seek + decode for each frame. AVAssetReader
//  decodes the GOP once and yields frames as they're decoded.
//

import AVFoundation
import CoreVideo
import Foundation
import os.log

actor FrameIterator {

    private let log = Logger(subsystem: "com.playercut.app", category: "FrameIter")

    private let asset: AVAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init(url: URL) {
        self.asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    /// Resets the reader to start at `startTime` and read at most until
    /// `endTime`. Output buffers come back at the requested resolution
    /// (smaller is faster — 320×180 for the analysis proxy).
    func seek(to startTime: Double,
              endTime: Double,
              outputSize: CGSize) async throws {

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.stage1Failed("No video track")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: max(0, endTime - startTime),
                             preferredTimescale: 600)
        )

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack,
                                              outputSettings: settings)
        output.alwaysCopiesSampleData = false  // critical for perf
        guard reader.canAdd(output) else {
            throw PipelineError.stage1Failed("Cannot add reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw PipelineError.stage1Failed(
                "Reader failed: \(reader.error?.localizedDescription ?? "?")")
        }

        self.reader = reader
        self.output = output
    }

    /// Yields the next frame in (time, pixelBuffer) form. Returns nil at end.
    /// Skip frames cheaply by calling repeatedly without doing work — the
    /// reader still has to decode them, but you avoid Vision overhead.
    func next() -> (time: Double, buffer: CVPixelBuffer)? {
        guard let output, let reader, reader.status == .reading else {
            return nil
        }
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return (pts, buffer)
    }

    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }

    // MARK: - Convenience: stride-based iteration

    /// Iterates frames at approximately the requested fps. Lower-cost than
    /// requesting individual times because we skip-decode rather than seek.
    func iterate(targetFPS: Double,
                 perform: (Double, CVPixelBuffer) async throws -> Void) async throws {

        let interval = 1.0 / targetFPS
        var lastEmittedTime: Double = -.infinity

        while let (time, buffer) = next() {
            if time - lastEmittedTime < interval { continue }
            lastEmittedTime = time
            try await perform(time, buffer)
        }
    }
}
