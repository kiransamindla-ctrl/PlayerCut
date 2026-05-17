# PlayerCut

On-device iOS app that records a youth sports game and produces a 60-second vertical highlight reel of just the tagged child.

## Hard rules (do not violate)

1. **No LLMs in the runtime.** Apple Vision, AVFoundation, classical signal processing only.
2. **No cloud, no network calls.** All processing on-device. Children's content never leaves the phone.
3. **No third-party SDKs.** Apple frameworks only. Every SDK is a privacy surface.
4. **No scoring, no rating, no coaching feedback.** Highlight reel only. Adding judgment invites lawsuits and parent drama.
5. **COPPA defense:** non-enrolled person bounding boxes are blurred before any clip is saved.

## Architecture (read these files first)

- `PlayerCut/PlayerCutApp.swift` — entry point
- `PlayerCut/Pipeline/PipelineOrchestrator.swift` — runs the stages
- `PlayerCut/Stages/Stage1CoarseDetector.swift` — audio + optical flow, cheap
- `PlayerCut/Stages/Stage2PlayerLocalizer.swift` — heavy ML on candidates only
- `PlayerCut/Pipeline/HighlightRanker.swift` — clip selection with diversity
- `PlayerCut/Composition/ReelComposer.swift` — 9:16 MP4 output
- `PlayerCut/Background/BackgroundProcessingV2.swift` — BG tasks + foreground fallback

## Performance constraints

- iPhone 13+ minimum (A15 Neural Engine)
- 1080p30 HEVC capture
- ≤20 min total processing on iPhone 13
- ≤200 MB peak memory (iOS BG task budget)
- ≤30 MB output MP4

## Coding conventions

- Swift 5.10, iOS 17 minimum
- Actor-based concurrency
- `Logger(subsystem: "com.playercut.app", category: ...)` for all logging
- No `print()` statements
- Errors via `PipelineError` enum in `CoreModels.swift`

## Build

```
xcodebuild -project PlayerCut.xcodeproj -scheme PlayerCut \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## Test

```
xcodebuild test -project PlayerCut.xcodeproj -scheme PlayerCut \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Known open questions (don't pretend these are solved)

- Jersey OCR accuracy at 20+ meters — needs field test
- Vision pose detection with 22 players in frame — Apple historically caps at 7
- Thermal throttling on 90-min summer recording
- Indoor lighting white-balance flicker
