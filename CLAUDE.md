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

## Pre-delivery smoke test protocol (mandatory)

Before telling the user "ready to test", run every step. Do NOT declare
done if any step fails — fix and re-run.

### A. Code-level checks
1. `xcodebuild build -project PlayerCut.xcodeproj -scheme PlayerCut -destination 'platform=iOS Simulator,name=iPhone 17'` → BUILD SUCCEEDED.
2. `xcodebuild test -project PlayerCut.xcodeproj -scheme PlayerCut -destination 'platform=iOS Simulator,name=iPhone 17'` → all tests pass; record the count.
3. `xcodebuild build -project PlayerCut.xcodeproj -scheme PlayerCut -destination 'platform=iOS,id=<connected-device>' -allowProvisioningDeviceRegistration` → BUILD SUCCEEDED. Auto-detect the connected device via `xcrun devicectl list devices`.
4. `xcrun devicectl device install app --device <id> <derived-data>/.../PlayerCut.app` → "App installed".

### B. Device launch verification
5. `xcrun devicectl device process launch --device <id> com.playercut.app` → "Launched application".
6. Stream device logs for 15 seconds: `log stream --device --predicate 'subsystem == "com.playercut.app"' --timeout 15s`.
7. Verify the log contains NO fatal errors, NO crashes, NO obvious setup failures (e.g. "PipelineError error 0", "captureFailed", "permission denied"). If the device prompts for trust (first install with this cert), note that as user-required validation, not a failure.

### C. Automated UI tests
8. PlayerCutUITests target exists (under PlayerCutUITests/, declared in project.yml).
9. XCUITest coverage for each user-visible flow added in the most recent changes:
   - Launch → root view present
   - Enrollment sheet opens via "Enroll a player" / "Add player"
   - Capture sheet opens via "Record game"
   - Compilation sheet opens via "Compilation"
   - Settings sheet opens via the gear toolbar item
   Use SwiftUI `.accessibilityIdentifier(_:)` on the entry points so XCUITest can find them deterministically.
10. `xcodebuild test -project PlayerCut.xcodeproj -scheme PlayerCut -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PlayerCutUITests` → all UI tests pass.

### D. Required: do not declare ready if anything failed
Fix the underlying issue and re-run the entire protocol. Don't bypass a step; don't skip retries.

### E. Required in the delivery summary
- All build outputs as a table: simulator build / sim tests / device build / install / launch (✅ / ❌).
- All test results with counts (unit + UI separately).
- A short device-log excerpt showing a clean startup (or the line that surfaced the failure).
- The list of UI tests run and their pass status.
- A clearly labelled "User-required validation" section enumerating anything only the human can verify — Untrusted Developer trust step, camera framing, real motion data, real outdoor/indoor lighting for scene-detection signoff, etc.

## Known open questions (don't pretend these are solved)

- Jersey OCR accuracy at 20+ meters — needs field test
- Vision pose detection with 22 players in frame — Apple historically caps at 7
- Thermal throttling on 90-min summer recording
- Indoor lighting white-balance flicker
