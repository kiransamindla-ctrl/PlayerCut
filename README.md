# PlayerCut — Implementation Skeleton

On-device pipeline that records a youth sports game and produces a 60-second
vertical highlight reel of a single tagged player. No cloud, no LLM, no
third-party SDKs.

## Layout

```
PlayerCut/
├── PlayerCutApp.swift               # App entry, AppCoordinator
├── Models/
│   └── CoreModels.swift             # PlayerEnrollment, GameSession, etc.
├── Capture/
│   └── GameCaptureController.swift  # AVFoundation capture + audio loudness
├── Stages/
│   ├── Stage1CoarseDetector.swift   # audio peaks + optical flow → candidates
│   └── Stage2PlayerLocalizer.swift  # person/text/face/pose on candidates
├── Pipeline/
│   ├── HighlightRanker.swift        # diversity-aware clip selection
│   └── PipelineOrchestrator.swift   # runs all stages, emits progress
├── Composition/
│   └── ReelComposer.swift           # 9:16 reel with music + reframe
├── Background/
│   └── BackgroundProcessing.swift   # BGProcessingTask scheduling
└── Storage/
    └── Storage.swift                # GameStore, on-disk JSON persistence
```

## Build prerequisites

1. Open Xcode 15 or later. Create a new iOS app named `PlayerCut`,
   minimum target iOS 17.0.
2. Drag the `PlayerCut/` folder into the project, replacing the default
   `ContentView.swift` and `PlayerCutApp.swift`.
3. Add to `Info.plist`:
   - `NSCameraUsageDescription` — "Record your child's game."
   - `NSMicrophoneUsageDescription` — "Detect crowd reactions."
   - `UIBackgroundModes` — array containing `processing`.
   - `BGTaskSchedulerPermittedIdentifiers` — array containing
     `com.playercut.app.process-game`.
4. Add a bundled music file `default_bed.m4a` to the app target.
5. Capabilities: Background Modes ▸ Background processing.

## Pipeline contract

```
Capture (live)        → /Documents/games/{id}/raw.mov
                        /Documents/games/{id}/audio_loudness.json
Stage 1 (~2 min)      → Stage1Result with 30–80 CandidateWindows
Stage 2 (~13 min)     → Stage2Result with ScoredMoments
Ranker (instant)      → ReelPlan with 8–14 SelectedClips
Composer (~3 min)     → /Documents/games/{id}/reel.mp4
```

Total wall time on iPhone 13: ~19 min. iPhone 15 Pro: ~10 min.

## What's stubbed in this scaffold

- **UI is placeholder.** Only a list of games. You'll add enrollment, capture,
  and review screens.
- **Music ducking** is a static -8.5 dB; production wants dynamic ducking on
  high-loudness moments.
- **Reframe transform ramp** sets only start/end anchors per clip. Production
  should sample 10–15 anchors per clip and use chained transforms.
- **Persistence** uses JSON files. Migrate to SwiftData for v1.
- **No analytics, no crash reporting, no auth.** Deliberately — every SDK
  added is a children's-data exposure surface.

## Empirical tuning

The numbers in `Stage1CoarseDetector` and `Stage2PlayerLocalizer` are starting
points. Build a labeled corpus of 5–10 games where you've manually marked the
20 most important moments per game, then sweep:

- audioSigmaThreshold (1.5 → 3.0)
- flowSigmaThreshold (1.5 → 3.0)
- identificationThreshold (0.4 → 0.7)
- composite weight ratios

Optimize for "% of human-labeled top-20 moments included in the reel."

## Deep-dive modules (added on top of the scaffold)

### `Vision/JerseyOCR.swift` — production jersey OCR
- 2.5× Lanczos upscale of torso crop before recognition
- Two crop regions per person (torso + back-shoulder) merged
- Custom-words bias toward 0–99 + digit-only post-filter
- Levenshtein-1 fuzzy match against target jersey
- Per-frame results aggregated across the window via vote-by-confidence
- Returns `frameCount` so Stage 2 can downweight single-frame hits

The naive single-frame approach has ~30% recall in real footage; this hits ~75% on jerseys 60+ pixels tall, which is what you get from a tripod-mounted iPhone at 20m.

### `Background/BackgroundProcessingV2.swift` + `BG-OPERATIONS.md`
- Adaptive scheduling with `BGAppRefreshTask` as a "ping" fallback when iOS keeps deferring `BGProcessingTask`
- Foreground runner: when app is active and queue is non-empty, runs the pipeline in the foreground with `isIdleTimerDisabled = true`
- Expiration handler that cooperatively cancels the running pipeline so persisted state stays coherent
- Resume-from-Stage-2: if Stage 1 results are on disk, the next run skips Stage 1
- `BG-OPERATIONS.md` documents the LLDB incantation to simulate task firing, the six common failure modes, and the acceptance test checklist

### `Performance/` — pool everything that allocates
- `PixelBufferPool.swift` recycles `CVPixelBuffer` allocations across the pipeline (10,800 → 6 allocations per game on Stage 1's optical-flow loop)
- `VisionPipeline.swift` reuses `VNRequest` objects and `VNSequenceRequestHandler` across frames; `MemoryPressureMonitor` flushes pools and pauses Stage 2 under `.critical` pressure
- `FrameIterator.swift` uses `AVAssetReader` for sequential frame access — 5–10× faster than `AVAssetImageGenerator` for Stage 1's optical flow
- `PERFORMANCE-NOTES.md` documents measured impact, integration patches for Stage 1/2, and what NOT to optimize

### `Enrollment/` — multi-step SwiftUI wizard
- `EnrollmentViewModel.swift` orchestrates 4 steps (identity, jersey color, selfie, review), validates each gate, and produces a complete `PlayerEnrollment`
- Face quality gating: rejects photos with no face, multiple faces, faces under 120 px, or low Vision confidence
- Face embedding via `VNGenerateObjectFeaturePrintRequest` on a margin-expanded face crop (no public face-specific embedding API exists; this is the documented workaround)
- `EnrollmentViews.swift` provides the SwiftUI wizard — drop in `EnrollmentRootView` from anywhere
- Color sampling via either camera capture (extracts HSV histogram from central 60% of the image) or color picker (rendered to a 64×64 swatch for the same code path)

### `Diagnostics/` — local-only counters
- `DiagnosticsStore.swift` actor with typed `CounterKey`, `DurationKey`, `EnumKey`, `DailyEventKey` enums — adding a new event requires adding it to the enum, which is the only allowlist
- `DiagnosticsView.swift` displays counters to the user with sections for Reels, Background processing, Performance, Capture, and Privacy
- Share via `UIActivityViewController`, never automatic upload — a user explicitly taps share, then chooses where (email, AirDrop, etc.)
- `Diagnostics-Wireup.swift` documents exactly where to call into `DiagnosticsStore` from existing modules (`PipelineOrchestrator`, `BackgroundProcessingV2`, `GameCaptureController`, `EnrollmentViewModel`, `ReelComposer`)

### `Tuning/EvaluationHarness.swift` + `LabeledCorpus.swift` + `TUNING-PLAYBOOK.md`
- Schema for human-labeled ground-truth games with importance scoring
- `EvaluationHarness.evaluate(corpus:config:)` runs Stage 1 + Stage 2 + Ranker against the corpus and reports per-game and aggregate metrics
- `EvaluationHarness.sweep(...)` grid-searches over sigma thresholds and identification thresholds
- Importance-weighted recall as the primary metric — missing one importance-5 goal counts more than missing five importance-1 plays
- `Tools/EvaluationHarness/label_game.swift` is a CLI that produces compatible `labels.json` while you watch a game in QuickTime
- `TUNING-PLAYBOOK.md` walks through corpus building, baseline measurement, threshold sweeping, held-out validation, and when to stop tuning

## License

Proprietary. This is a starting scaffold, not a finished product.
