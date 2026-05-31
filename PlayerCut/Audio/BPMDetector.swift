//
//  BPMDetector.swift
//  PlayerCut/Audio
//
//  Native Swift BPM detector. AVAssetReader → 16 kHz mono PCM → 100 Hz
//  RMS envelope → DC-removed autocorrelation across lags spanning
//  60–200 BPM → quadratic-refined peak → (bpm, confidence). Same
//  template as AudioPeakDetector (read source, walk hops, never spawn
//  a sidecar). Used at runtime so any BYO music gets a real BPM.
//
//  The math is the standard autocorrelation-of-onset-envelope approach
//  (Klapuri 1999, Dixon 2007) — porting the intent of the prior Python
//  `recompute_bpm.py` into Apple-native code so we can drop the
//  manifest-BPM dependency for imported tracks.
//
//  // SOURCE: developer.apple.com/documentation/avfoundation/avassetreader
//  // accessed 2026-05-30 — confirms 16 kHz mono int16 output settings
//  // are valid for any iOS-supported audio asset.
//
//  Cost (75 s track, 100 Hz envelope = 7500 samples, ~70 lags) is
//  ~0.5 M multiply-adds in the autocorr — microseconds on A15+.
//

import Accelerate
import AVFoundation
import Foundation
import os.log

enum BPMDetector {

    /// Renamed from `log` to avoid colliding with the Darwin natural-log
    /// function used inside the autocorrelation prior.
    private static let logger = Logger(subsystem: "com.playercut.app",
                                       category: "BPMDetector")

    /// Sample rate of the decoded PCM the envelope is built from. Same
    /// as AudioPeakDetector so cached AVAssetReader pipelines stay warm.
    private static let sampleRate: Double = 16_000
    /// Envelope rate. 10 ms hops → 100 Hz, the standard rate for
    /// onset-envelope autocorrelation BPM detectors.
    private static let envelopeRate: Double = 100
    private static let hopFrames: Int = Int(sampleRate / envelopeRate)  // 160

    /// Search window: 60–200 BPM.
    ///   60 BPM = 1.000 s / beat → lag = 100 envelope samples
    ///  200 BPM = 0.300 s / beat → lag = 30  envelope samples
    private static let minBPM: Double = 60
    private static let maxBPM: Double = 200
    /// Confidence floor — normalized autocorrelation (peak ÷ zero-lag
    /// energy, range [0,1]) below this means the envelope has no usable
    /// periodicity (silence, noise, a non-musical recording). 0.05 is
    /// well above the noise floor for any music with a beat and trips
    /// only on flat / DC-only envelopes.
    private static let confidenceFloor: Double = 0.05

    struct Result: Equatable {
        let bpm: Double
        let confidence: Double
        /// True when the detector's confidence fell below `confidenceFloor`
        /// and the caller should fall back to 120 BPM (or another safe
        /// per-context default).
        let didFallback: Bool
    }

    /// Fallback BPM when confidence is too low. 120 is the mid-point of
    /// the search range and a safe default for the editor's beat-snap.
    static let fallbackBPM: Double = 120

    // MARK: - Public entry point

    static func detect(url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audio = tracks.first else {
                logger.warning("BPMDetect: no audio track in \(url.lastPathComponent, privacy: .public) — fallback 120 BPM")
                return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
            }
            let r = await detect(asset: asset, audioTrack: audio)
            // S8 + PR #10 — manifest.json is now seeded from this same
            // detector (BPMManifestRebuildTests, 2026-05-31), so any
            // divergence > 2 BPM means the detector's output drifted
            // since the last manifest rebuild. Tighter threshold than
            // the prior >5; same code path. Fires only on bundled tracks
            // (manifest lookup returns nil for BYO imports).
            if let manifestBPM = manifestBPM(forID: url.deletingPathExtension().lastPathComponent),
               abs(Double(manifestBPM) - r.bpm) > 2,
               !r.didFallback {
                logger.warning("BPMDetect: manifest divergence for \(url.lastPathComponent, privacy: .public) — manifest=\(manifestBPM) detected=\(r.bpm, format: .fixed(precision: 1)) (Δ=\(abs(Double(manifestBPM) - r.bpm), format: .fixed(precision: 1))). Re-run BPMManifestRebuildTests to refresh.")
            }
            return r
        } catch {
            logger.warning("BPMDetect: loadTracks failed (\(error.localizedDescription, privacy: .public)) — fallback 120 BPM")
            return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
        }
    }

    /// Looks up the manifest BPM for a bundled track id (e.g. "energetic_1").
    /// Returns nil for any non-bundled / non-manifest asset (BYO imports,
    /// test fixtures) so the divergence log fires only on the canonical
    /// 20-track Pixabay pool.
    private static func manifestBPM(forID id: String) -> Int? {
        guard let url = Bundle.main.url(forResource: "manifest",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]]
        else { return nil }
        for entry in tracks {
            if (entry["id"] as? String) == id,
               let bpm = entry["bpm"] as? Int {
                return bpm
            }
        }
        return nil
    }

    static func detect(asset: AVAsset, audioTrack: AVAssetTrack) async -> Result {
        guard let envelope = decodeEnvelope(asset: asset, audioTrack: audioTrack),
              envelope.count >= Int(envelopeRate)  // at least 1 s of audio
        else {
            logger.warning("BPMDetect: envelope too short — fallback")
            return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
        }
        return analyze(envelope: envelope)
    }

    // MARK: - Envelope decode

    /// AVAssetReader → 16 kHz mono int16 → 10 ms-hop RMS → Double array
    /// at 100 Hz. Mirrors AudioPeakDetector's read pattern so device
    /// behavior matches exactly. Returns nil on read failure.
    private static func decodeEnvelope(asset: AVAsset,
                                       audioTrack: AVAssetTrack) -> [Double]? {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            logger.warning("BPMDetect: reader init failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // RMS-hop walker. Carry-over buffer absorbs sub-hop tails between
        // sample buffers so hop boundaries land on the same source samples
        // regardless of how the demuxer chunks the file.
        var envelope: [Double] = []
        envelope.reserveCapacity(1024)
        var carry: [Int16] = []

        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let raw = ptr, length >= 2 else { continue }
            let n = length / 2
            let chunk: [Int16] = raw.withMemoryRebound(to: Int16.self, capacity: n) { p in
                Array(UnsafeBufferPointer(start: p, count: n))
            }
            carry.append(contentsOf: chunk)

            var i = 0
            while i + hopFrames <= carry.count {
                var sumSq: Double = 0
                for j in i..<(i + hopFrames) {
                    let v = Double(carry[j])
                    sumSq += v * v
                }
                envelope.append((sumSq / Double(hopFrames)).squareRoot())
                i += hopFrames
            }
            if i > 0 { carry.removeFirst(i) }
        }
        if reader.status == .failed {
            logger.warning("BPMDetect: reader failed (\(reader.error?.localizedDescription ?? "nil", privacy: .public))")
            if envelope.isEmpty { return nil }
        }
        return envelope.isEmpty ? nil : envelope
    }

    // MARK: - Analysis

    /// Pure-array entry point. Used by tests to feed synthetic envelopes
    /// (e.g. an impulse train at 120 BPM) without going through AVAsset.
    static func analyze(envelope: [Double]) -> Result {
        let n = envelope.count
        guard n >= Int(envelopeRate) else {
            return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
        }

        // 1. DC removal — subtract the mean so flat envelopes don't dominate
        //    the autocorrelation. (Equivalent to a 0 Hz high-pass.)
        var mean: Double = 0
        envelope.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            vDSP_meanvD(ptr, 1, &mean, vDSP_Length(n))
        }
        var hp = [Double](repeating: 0, count: n)
        var negMean = -mean
        envelope.withUnsafeBufferPointer { srcBuf in
            hp.withUnsafeMutableBufferPointer { dstBuf in
                guard let srcPtr = srcBuf.baseAddress,
                      let dstPtr = dstBuf.baseAddress else { return }
                vDSP_vsaddD(srcPtr, 1, &negMean,
                            dstPtr, 1, vDSP_Length(n))
            }
        }

        // 2. Lag range derived from BPM bounds. envelopeRate sample/s ×
        //    60 s/min ÷ BPM = lag in envelope samples.
        let minLag = max(2, Int((envelopeRate * 60 / maxBPM).rounded()))   // ~30
        let maxLag = min(n - 1, Int((envelopeRate * 60 / minBPM).rounded())) // ~100
        guard maxLag > minLag + 2 else {
            return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
        }

        // 3. Zero-lag energy R(0) = Σ hp[i]² — the normalization base
        //    for the autocorrelation. Confidence becomes peak ÷ R(0),
        //    which lives in [-1, 1] and is robust to envelope scale.
        var r0: Double = 0
        hp.withUnsafeBufferPointer { hpBuf in
            guard let ptr = hpBuf.baseAddress else { return }
            vDSP_svesqD(ptr, 1, &r0, vDSP_Length(n))
        }
        guard r0 > 1e-12 else {
            return Result(bpm: fallbackBPM, confidence: 0, didFallback: true)
        }

        // 4. Biased autocorrelation across the lag window, weighted by a
        //    perceptual tempo prior. Pure autocorrelation locks onto the
        //    shortest sub-beat (200 BPM hi-hat pulse, 1/8th, etc.) on
        //    music with strong upper harmonics; multiplying by a log-
        //    Gaussian centered at 120 BPM with σ ≈ 0.5 in log-BPM space
        //    steers the pick to the perceptually-correct beat without
        //    forbidding faster / slower tempos.
        //  // SOURCE: Klapuri, "Sound onset detection by applying
        //  // psychoacoustic knowledge" (1999); Dixon, "Evaluation of the
        //  // audio beat tracking system BeatRoot" (2007). Both establish
        //  // tempo prior as the standard cure for the octave-error
        //  // failure mode in autocorr-based BPM detectors.
        // `Foundation.log` qualifier sidesteps the name overlap with the
        // static logger property.
        let priorCenterLogBPM: Double = Foundation.log(120.0)
        let priorSigma: Double = 0.5
        var acf = [Double](repeating: 0, count: maxLag - minLag + 1)
        var biased = [Double](repeating: 0, count: acf.count)
        hp.withUnsafeBufferPointer { hpBuf in
            guard let basePtr = hpBuf.baseAddress else { return }
            for lag in minLag...maxLag {
                var dot: Double = 0
                vDSP_dotprD(basePtr, 1,
                            basePtr + lag, 1,
                            &dot, vDSP_Length(n - lag))
                let raw = dot / r0
                acf[lag - minLag] = raw
                let bpmAtLag: Double = envelopeRate * 60 / Double(lag)
                let dLog: Double = Foundation.log(bpmAtLag) - priorCenterLogBPM
                let denom: Double = 2 * priorSigma * priorSigma
                let w: Double = Foundation.exp(-(dLog * dLog) / denom)
                biased[lag - minLag] = raw * w
            }
        }

        // 5. Peak pick on the biased curve, but report confidence from
        //    the unbiased autocorr so a low-energy bass-drum still flags
        //    as low confidence even when the prior keeps it in range.
        var peakIdx = 0
        var peakVal = -Double.infinity
        for (i, v) in biased.enumerated() where v > peakVal {
            peakVal = v
            peakIdx = i
        }
        let lagInt = peakIdx + minLag
        var refinedLag = Double(lagInt)
        // Sub-bin refinement uses the biased curve we picked on so the
        // interpolated apex matches the peak we actually chose.
        if peakIdx > 0, peakIdx < biased.count - 1 {
            let y1 = biased[peakIdx - 1]
            let y2 = biased[peakIdx]
            let y3 = biased[peakIdx + 1]
            let denom = (y1 - 2 * y2 + y3)
            if abs(denom) > 1e-12 {
                let delta = 0.5 * (y1 - y3) / denom
                if delta.isFinite, abs(delta) < 1 {
                    refinedLag += delta
                }
            }
        }

        // 6. Confidence is the UNBIASED normalized autocorr at the picked
        //    lag — in [0,1] for any envelope with real periodicity. We
        //    don't use the biased value so a low-energy beat still flags
        //    as low confidence even when the prior keeps it in range.
        let confidence = acf[peakIdx]
        let didFallback = !confidence.isFinite || confidence < confidenceFloor

        let bpm: Double = {
            guard refinedLag > 0 else { return fallbackBPM }
            return min(maxBPM, max(minBPM, envelopeRate * 60 / refinedLag))
        }()

        if didFallback {
            logger.warning("BPMDetect: low confidence \(confidence, format: .fixed(precision: 2)) at \(bpm, format: .fixed(precision: 1)) BPM — falling back to \(fallbackBPM)")
            return Result(bpm: fallbackBPM, confidence: confidence, didFallback: true)
        }
        return Result(bpm: bpm, confidence: confidence, didFallback: false)
    }
}
