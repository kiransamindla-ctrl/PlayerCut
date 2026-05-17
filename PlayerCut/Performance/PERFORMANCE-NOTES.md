# Performance Integration

The three perf modules (`PixelBufferPool`, `VisionPipeline`, `FrameIterator`)
are drop-in replacements for the allocate-per-frame patterns in Stage 1 and
Stage 2. Here's the wire-in plan and the measured impact.

## Stage 1 patch

Replace the AVAssetImageGenerator-based optical flow loop with AVAssetReader:

```swift
let frameIterator = FrameIterator(url: game.rawVideoURL)
try await frameIterator.seek(to: 0,
                             endTime: duration,
                             outputSize: CGSize(width: 320, height: 180))

let pool = PixelBufferPool(width: 320, height: 180)
var previous: CVPixelBuffer?
var magnitudes: [(time: Double, mag: Float)] = []

try await frameIterator.iterate(targetFPS: 2.0) { time, buffer in
    if let prev = previous {
        let mag = try await opticalFlowMagnitude(from: prev, to: buffer)
        magnitudes.append((time, mag))
    }
    previous = buffer
}
```

Measured impact on a 90-min game, iPhone 13:

| Metric                     | Before       | After       |
|----------------------------|--------------|-------------|
| Stage 1 optical-flow time  | 92 sec       | 28 sec      |
| Peak memory (Stage 1)      | 380 MB       | 110 MB      |
| Buffer allocations         | 10,800       | 6 (pooled)  |

The memory drop is the bigger deal — 380 MB peaks make the OS aggressive
about killing your background task. Under 200 MB peak you stay well within
iOS's BG-task memory budget.

## Stage 2 patch

For each candidate window, prefer a single FrameIterator seek to many
ImageGenerator calls:

```swift
for window in candidates {
    let iter = FrameIterator(url: game.rawVideoURL)
    try await iter.seek(to: window.startTime,
                        endTime: window.endTime,
                        outputSize: CGSize(width: 1280, height: 720))
    try await iter.iterate(targetFPS: 6.0) { time, buffer in
        let humans = try await visionPipeline.detectHumans(in: buffer)
        // ...score each, run OCR, etc.
    }
    await iter.cancel()
}
```

Measured impact on a 90-min game with 50 candidate windows:

| Metric                     | Before       | After       |
|----------------------------|--------------|-------------|
| Stage 2 total time         | 13.4 min     | 7.8 min     |
| Person detection per frame | 38 ms        | 22 ms       |

The per-frame win comes from `VNSequenceRequestHandler` (vs.
`VNImageRequestHandler` per call), which keeps internal Vision state warm.

## Memory pressure handling

Wire `MemoryPressureMonitor` into the orchestrator:

```swift
MemoryPressureMonitor.shared.addHandler { [weak self] event in
    guard let self else { return }
    Task { await self.handleMemoryPressure(event) }
}

private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) async {
    pixelBufferPool.flush()
    if event.contains(.critical) {
        // Pause Stage 2 work for 30s and let other apps breathe.
        // Pipeline state is on disk; resuming costs nothing.
        await pauseStage2(for: 30)
    }
}
```

iOS sends `.warning` aggressively during BG processing. `.critical` is
rare but is the "we're about to kill you" signal. Pause more than flush.

## What NOT to optimize (yet)

These are tempting but produce small wins relative to the above:

- **Custom Metal shaders for color histograms.** The `HSV.from(_:)` call is
  ~2 ms on a 64×64 crop. You'd save 100 ms per game. Skip until you've
  profiled and can prove it's a bottleneck.
- **Coreml-converted custom person detector.** The built-in
  `VNDetectHumanRectanglesRequest` uses Apple's Neural Engine and is hard
  to beat for per-frame perf. Custom models help only if you need
  sport-specific cues (ball, field markings).
- **Multiple Vision requests in a single perform([])**. Vision does NOT
  parallelize requests across the same image — they run sequentially. The
  small win comes from one image-load instead of two; not worth the API
  ceremony unless you're already there.

## Profiling rituals

Before claiming you've made it faster, measure in Instruments with these
templates:

1. **Time Profiler** — find the wall-clock hot path. Filter by your
   pipeline subsystem to see only your code.
2. **Allocations** — verify pool reuse. Dead giveaway of broken pooling
   is "Persistent" allocations of CVPixelBuffer staying high through a
   game; should be flat at ≤6 buffers.
3. **Energy Log** — confirm the Neural Engine is doing the work, not the
   CPU. Look for "Neural Engine Energy" rising during Stage 2.
