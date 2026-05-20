# PlayerCut — Feature Inventory (evidence-based, verification-honest)

Generated 2026-05-20 from the source tree at HEAD (`7b5f1a2`).

Reading basis: `find PlayerCut PlayerCutTests PlayerCutUITests -name "*.swift"`
(54 source files, 14 169 lines including tests + manifest), plus
`project.yml` exclusion list and `git log --oneline -30`.

**Core flow being measured against:**
`open app → see live camera preview → tap record → stop → reel that plays in-app and saves to Photos`

**Verification rubric (strict):**
- **VERIFIED-DEVICE** — concrete evidence the feature ran correctly on
  physical hardware (a device test, a logged success, or a commit that
  demonstrably fixed it on-device). Evidence cited.
- **VERIFIED-SIM-ONLY** — a passing XCTest exercises the feature in
  the simulator; no on-device proof.
- **UNVERIFIED** — code compiles; no test, no logged success, no
  device confirmation. The default unless there is positive evidence.

`xcodebuild build` succeeding for the device target proves the app
**links and installs** on the device. It does NOT prove any feature
behaves correctly. That bar is "VERIFIED-DEVICE" and requires more.

---

## 1. Feature table

| # | Feature | Files | CriticalPath | Risk | Verification | Evidence |
|---|---------|-------|--------------|------|--------------|----------|
| 1 | App entry + scene-phase brightness restore | `PlayerCut/PlayerCutApp.swift` | CORE | NON-BLOCKING | UNVERIFIED | No test; only manual install + launch on iPhone 14 Plus (commit `7b5f1a2`) — proves launch, not state restoration |
| 2 | Terms / welcome gate (fullScreenCover until accepted) | `PlayerCut/Onboarding/WelcomeView.swift` | CORE | **BLOCKING** | UNVERIFIED | No test; gate stands between launch and any other screen |
| 3 | Permissions primer gate (fullScreenCover until done) | `PlayerCut/Onboarding/PermissionsPrimerView.swift` | CORE | **BLOCKING** | UNVERIFIED | No test |
| 4 | Player enrollment wizard (identity → jersey color → selfie → reel length → music vibe → review) | `PlayerCut/Enrollment/EnrollmentViews.swift`, `EnrollmentViewModel.swift` | CORE | **BLOCKING** | VERIFIED-SIM-ONLY (open-only) | `PlayerCutUITests.testEnrollSheetOpens` proves the sheet opens; no test exercises the full wizard or selfie/embedding |
| 5 | Root view + navigation (player cards + games strip + CTA) | `PlayerCut/PlayerCutApp.swift` (`RootView`) | CORE | NON-BLOCKING | VERIFIED-SIM-ONLY | `PlayerCutUITests.testAppLaunches` finds `hero-title` |
| 6 | Camera permission request + error banner | `PlayerCut/Capture/CaptureView.swift` (`onAppear`) | CORE | **BLOCKING** | UNVERIFIED | No test; failure surfaces `errorMessage`, preview never starts |
| 7 | Capture session setup — Phase 1 (inputs/outputs/start) | `PlayerCut/Capture/GameCaptureController.swift` (`configure`, lines 70-180) | CORE | NON-BLOCKING | UNVERIFIED | Commit `7b5f1a2` reworked it to "never block preview" but device launch was blocked by locked phone — fix is **not** confirmed end-to-end on hardware |
| 8 | Camera preview (AVCaptureVideoPreviewLayer) | `PlayerCut/Capture/CaptureView.swift` (`CameraPreviewView`) | CORE | NON-BLOCKING | UNVERIFIED | User reported BLACK on previous build (`6bfec78`); fix `7b5f1a2` not yet user-verified |
| 9 | 3-second preview watchdog (force-restart if session not running) | `PlayerCut/Capture/CaptureView.swift` (`schedulePreviewWatchdog`), `GameCaptureController.swift` (`forceRestartIfStalled`) | CORE | NON-BLOCKING | UNVERIFIED | Added in commit `7b5f1a2`; never tripped in any logged session |
| 10 | Manual record button (start / stop) | `PlayerCut/Capture/CaptureView.swift` (`bottomBar`, `start`, `stop`) | CORE | NON-BLOCKING | UNVERIFIED | No UI test for record/stop; only gate is `configured` |
| 11 | Adaptive capture recipe selection (SoCTier → 4K60 / 1080p60 / 1080p30 step-down) | `PlayerCut/Capture/DeviceCapabilities.swift` | SUPPORTING | NON-BLOCKING | VERIFIED-SIM-ONLY | 18 tests in `PlayerCutTests.DeviceCapabilitiesTests` (tier mapping, recipe selection, ladder, slow-mo, JSON round-trip). Best-effort path means failure ≠ blocking preview |
| 12 | Thermal + battery live downgrade observers | `PlayerCut/Capture/GameCaptureController.swift` (`observeThermalAndBattery`, `evaluateDowngrade`) | SUPPORTING | NON-BLOCKING | VERIFIED-SIM-ONLY (ladder math only) | `DeviceCapabilitiesTests.testDowngrade*` covers pure thresholds; observer firing on real heat/battery transitions: UNVERIFIED |
| 13 | Indoor/outdoor scene detection (luminance pre-flight, 2 s timeout) | `PlayerCut/Capture/GameCaptureController.swift` (`SceneLuminanceDelegate`, `sampleSceneType`) | SUPPORTING | NON-BLOCKING | UNVERIFIED | Has timeout fallback; no test |
| 14 | Audio loudness sidecar (5 Hz RMS via vDSP) | `PlayerCut/Capture/GameCaptureController.swift` (audio tap extension) | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test |
| 15 | Brightness dim during recording + persistent restore | `PlayerCut/Capture/BrightnessKeeper.swift`, `CaptureView.swift` (`handleScenePhase`, `applyCapturePowerProfile`, `restorePowerProfile`), `PlayerCutApp.swift` (belt-and-braces restore on launch) | CONVENIENCE | NON-BLOCKING | UNVERIFIED | No test |
| 16 | Tap-to-wake overlay while dimmed | `PlayerCut/Capture/CaptureView.swift` (`screenDimmed`) | CONVENIENCE | NON-BLOCKING | UNVERIFIED | No test |
| 17 | Mount detection + 3 s auto-start countdown | `PlayerCut/Capture/MountDetector.swift`, `CaptureView.swift` (`handleMountStateChange`, `beginAutoStartCountdown`) | CONVENIENCE | NON-BLOCKING | UNVERIFIED | OFF by default after commit `7b5f1a2`; opt-in only |
| 18 | Auto-stop (declared in `SettingsKeys.autoStopEnabled`) | `PlayerCut/Settings/SettingsView.swift` | CONVENIENCE | NON-BLOCKING | UNVERIFIED — toggle exists, NO reader wired | grep for `autoStopEnabled` shows only the `@AppStorage` write site in SettingsView; no capture-side reader. Effectively dead. |
| 19 | Reel length picker (60s / 2min / 3min / 5min) on capture screen | `PlayerCut/Capture/CaptureView.swift` (`topBar`, `showingLengthPicker`), `CoreModels.ReelLength` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test |
| 20 | Game session persistence (Codable + relative-path reel resolution) | `PlayerCut/Models/CoreModels.swift` (`GameSession.encode/decode`), `PlayerCut/Storage/Storage.swift` (`GameStore`) | CORE | NON-BLOCKING | VERIFIED-SIM-ONLY | `CompositionTests.GameSessionRelativePathTests` (4 tests: rebuild, rebase, no-Documents salvage, JSON migration) |
| 21 | Background-task pipeline runner + foreground fallback | `PlayerCut/Background/BackgroundProcessingV2.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test; BG task firing requires iOS scheduler |
| 22 | Pipeline orchestrator (Stage1 → Stage2 → Ranker → Compose) + per-stage timing + ETA sample recording | `PlayerCut/Pipeline/PipelineOrchestrator.swift` | CORE | NON-BLOCKING | UNVERIFIED | No integration test; pure-logic stages tested individually |
| 23 | Stage 1 coarse detector (audio peaks + optical-flow proxy) | `PlayerCut/Stages/Stage1CoarseDetector.swift` | CORE | NON-BLOCKING | UNVERIFIED | No test for the stage itself |
| 24 | Stage 2 player localizer (person detect + jersey OCR + jersey color + face embedding) | `PlayerCut/Stages/Stage2PlayerLocalizer.swift` | CORE | NON-BLOCKING | UNVERIFIED | No test for the stage itself |
| 25 | Jersey OCR (window-level temporal voting) | `PlayerCut/Vision/JerseyOCR.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED (string-distance helper only) | `LevenshteinTests` (8 tests) covers the fuzzy-match primitive only |
| 26 | Vision pipeline + memory-pressure handler | `PlayerCut/Performance/VisionPipeline.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No test |
| 27 | Frame iterator (AVAssetReader → CVPixelBuffer stream) | `PlayerCut/Performance/FrameIterator.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No test |
| 28 | Pixel buffer pool | `PlayerCut/Performance/PixelBufferPool.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No test |
| 29 | Highlight ranker — 3-tier never-reject (Tier1 normal → Tier2 weakSignals → Tier3 montage fallback) | `PlayerCut/Pipeline/HighlightRanker.swift` | CORE | NON-BLOCKING | VERIFIED-SIM-ONLY | `HighlightRankerTests` (13 tests): diversity rule, clip bounds, chronological order, exceptional path, low-activity, all three tiers, single-strong-moment, empty inputs |
| 30 | EditPlan + builder (crop keyframes / speed curves / transition spec / titles / lower-third / beat grid) | `PlayerCut/Composition/EditPlan.swift`, `EditPlanBuilder.swift` | SUPPORTING | NON-BLOCKING | VERIFIED-SIM-ONLY | `EditPlanBuilderTests` (5): crop bounds, anti-jitter, speed-curve continuity, chill suppresses ramps, plan-duration shape, style ↔ vibe mapping, style → LUT |
| 31 | MetalPetal unified compositor (crop, grade, A/B transitions, rasterized overlays) | `PlayerCut/Composition/MetalPetalCompositor.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No fixture test; only `ComposerFallbackRegressionTests` (3) which asserts the no-fallback diagnostic invariant — does not exercise actual render |
| 32 | ReelComposer (AVMutableComposition + dual video tracks + per-stage fail-loud + 240 s watchdog) | `PlayerCut/Composition/ReelComposer.swift` | CORE | NON-BLOCKING | UNVERIFIED | No fixture test; regression test only checks the affirm-false invariant |
| 33 | Color LUT factory (procedural Vivid + Natural cubes) | `PlayerCut/Composition/LUTFactory.swift` | SUPPORTING | NON-BLOCKING | VERIFIED-SIM-ONLY | `LUTFactoryTests` (2): cube dimensions, endpoint preservation |
| 34 | Title / closing / lower-third card factory (CALayer + UIGraphicsImageRenderer rasterization) | `PlayerCut/Composition/TitleCardFactory.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test; static rasterization path added in `6bfec78` |
| 35 | Device-class perf profile (chip family → cinematic vs midRange vs conservative) | `PlayerCut/Composition/DeviceClass.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test; consulted by EditPlanBuilder |
| 36 | ETA estimator (per-SoC, per-stage EMA persisted to UserDefaults) | `PlayerCut/Composition/ETAEstimator.swift`, used by `Pipeline/PipelineOrchestrator.swift` and `Pipeline/GameDetailView.swift` | SUPPORTING | NON-BLOCKING | VERIFIED-SIM-ONLY | `ETAEstimatorTests` (3): cold-start, envelope tightening, overdue label |
| 37 | Photos library save (Add-Photos-Only friendly; album when full access) | `PlayerCut/Composition/PhotosLibraryService.swift` | CORE | NON-BLOCKING | UNVERIFIED | No test; gracefully falls back to local-only on denial |
| 38 | GameDetailView player (stable AVPlayer, scenePhase pause/resume, playable-URL gate, Re-process CTA, share sheet) | `PlayerCut/Pipeline/GameDetailView.swift` | CORE | NON-BLOCKING | UNVERIFIED | No test; designed to handle missing-file gracefully but never exercised on device |
| 39 | Composing-screen ETA panel + Stadium light-bar progress | `PlayerCut/Pipeline/GameDetailView.swift` (`etaPanel`, `StadiumLightBar`) | CONVENIENCE | NON-BLOCKING | VERIFIED-SIM-ONLY (ETA math only) | ETA reading math covered; rendering: UNVERIFIED |
| 40 | Compilation orchestrator (end-of-season multi-game stitch) | `PlayerCut/Compilation/CompilationOrchestrator.swift`, `CompilationView.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test; behind "Compilation" button (disabled until ≥ 2 completed games) |
| 41 | Pricing gate + paywall (free-trial reel counter + StoreKit-less paywall view) | `PlayerCut/Pricing/PricingModel.swift`, `PaywallView.swift` | SUPPORTING | NON-BLOCKING | UNVERIFIED | No test; `PricingGate.shouldShowPaywall` triggers fullScreenCover after N reels |
| 42 | Assisted-tier accessory recommendations sheet | `PlayerCut/Assisted/AssistedTierView.swift`, `Accessory.swift` | CONVENIENCE | NON-BLOCKING | UNVERIFIED | No test; shown once after first enrollment |
| 43 | Settings view (auto-start toggle, auto-stop toggle, diagnostics button) | `PlayerCut/Settings/SettingsView.swift` | INFRA | NON-BLOCKING | VERIFIED-SIM-ONLY (open-only) | `PlayerCutUITests.testSettingsSheetOpens` |
| 44 | Background-refresh status banner | `PlayerCut/Settings/BackgroundRefreshGuidance.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No test |
| 45 | Diagnostics store actor (counters, durations, enum distributions, daily events) | `PlayerCut/Diagnostics/DiagnosticsStore.swift` | INFRA | NON-BLOCKING | VERIFIED-SIM-ONLY (composer hooks) | `ComposerFallbackRegressionTests` (3): default-absent, affirm-false, stage-failed counter + distribution. Rest of the store: UNVERIFIED |
| 46 | Diagnostics view + JSON export share sheet | `PlayerCut/Diagnostics/DiagnosticsView.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No test |
| 47 | Design system (Theme + PCPillButton + PCStatusChip) | `PlayerCut/DesignSystem/Theme.swift` | INFRA | NON-BLOCKING | UNVERIFIED | No visual test |
| 48 | Levenshtein string distance helper | `PlayerCut/Utilities/StringDistance.swift` | INFRA | NON-BLOCKING | VERIFIED-SIM-ONLY | `LevenshteinTests` (8) |
| 49 | HSV histogram (jersey color match) | `PlayerCut/Models/CoreModels.swift` | INFRA | NON-BLOCKING | VERIFIED-SIM-ONLY | `HSVHistogramTests` (5) |
| 50 | Music manifest (BPM lookup table for bundled tracks) | `PlayerCut/Music/manifest.json` | SUPPORTING | NON-BLOCKING | UNVERIFIED | Manifest stubbed (`"file": null` per Dependencies.md "Pending"); no actual .m4a files in `PlayerCut/Music/` |
| 51 | BeaconScanner (BLE iBeacon ranging) | `PlayerCut/Beacon/BeaconScanner.swift` | CONVENIENCE | NON-BLOCKING | **DEAD CODE** | `grep -rn BeaconScanner PlayerCut --include="*.swift"` shows zero references outside its own file |
| 52 | ByteTracker (multi-object tracker) | `PlayerCut/Tracking/ByteTracker.swift` | SUPPORTING | NON-BLOCKING | **DEAD STUB** | Dependencies.md: "Stub only; full port pending". Zero external references |
| 53 | PoseSignal (pose-keypoint feature extractor) | `PlayerCut/Pose/PoseSignal.swift` | SUPPORTING | NON-BLOCKING | **DEAD CODE** | Zero external references |
| 54 | ThermalAndPowerMonitor (Combine `@Published` thermal + low-power) | `PlayerCut/Performance/ThermalAndPowerMonitor.swift` | INFRA | NON-BLOCKING | **DEAD CODE** | Only self-reference; `DeviceClass` and `GameCaptureController` read `ProcessInfo` directly |
| 55 | EvaluationHarness + LabeledCorpus (offline tuning harness) | `PlayerCut/Tuning/EvaluationHarness.swift`, `LabeledCorpus.swift` | INFRA | NON-BLOCKING | **DEAD CODE** (no production caller, no tests) | Zero references outside the Tuning folder |
| 56 | PlayerEnrollment.beaconID field | `PlayerCut/Models/CoreModels.swift` (`beaconID`) | CONVENIENCE | NON-BLOCKING | **DEAD DATA** | Stored + decoded but no enrollment step ever sets it; BeaconScanner never reads it |
| 57 | Stage2-JerseyOCR-Integration.swift (patch-diff documentation) | `PlayerCut/Vision/Stage2-JerseyOCR-Integration.swift` | INFRA | NON-BLOCKING | **EXCLUDED FROM BUILD** | `project.yml:24` excludes path |
| 58 | Diagnostics-Wireup.swift (patch-diff documentation) | `PlayerCut/Diagnostics/Diagnostics-Wireup.swift` | INFRA | NON-BLOCKING | **EXCLUDED FROM BUILD** | `project.yml:25` excludes path |

**Tally:**
- 13 CORE features. None are VERIFIED-DEVICE. Two are VERIFIED-SIM-ONLY (relative-path resolver, ranker). Eleven are UNVERIFIED.
- 14 SUPPORTING features. Three VERIFIED-SIM-ONLY (recipe selection, EditPlan, LUT). Two DEAD. Nine UNVERIFIED.
- 6 CONVENIENCE features. One DEAD (BeaconScanner). One DEAD-DATA (beaconID). Four UNVERIFIED.
- 8 INFRA features. Three VERIFIED-SIM-ONLY (Levenshtein, HSV, Diag composer hooks + Settings sheet open). Two EXCLUDED from build. Three UNVERIFIED.
- Plus: `autoStopEnabled` toggle exists with no reader (feature #18) — effectively dead UI control.

---

## 2. Front-of-path risks

Anything that sits between launch and the core flow and can break it.

| # | Risk | File:Lines | Why it's a risk |
|---|------|-----------|-----------------|
| A | **Welcome / terms gate is a `fullScreenCover(isPresented: .constant(!termsAccepted))`** | `PlayerCutApp.swift:154-156` | Hard-locked screen until `OnboardingKeys.termsAccepted` flips true; any bug in WelcomeView freezes the entire app for fresh installs |
| B | **Permissions primer gate is another `fullScreenCover`** | `PlayerCutApp.swift:157-163` | Same shape — until `PermissionPrimerKeys.primerDone` flips, the app is stuck on the primer |
| C | **Enrollment is required to reach Record** | `PlayerCutApp.swift:95-98` (empty-state branch) | If `coordinator.players.isEmpty`, the only CTA is "Enroll a player" — no recording until at least one enrollment lands. Selfie/embedding step has zero test coverage |
| D | **Camera permission denial leaves an `errorMessage` overlay; preview never starts** | `CaptureView.swift:151-156` | Recovery path is "Enable in Settings → PlayerCut"; user must leave app |
| E | **`PaywallView` triggers from `onChange(of: freeReelsUsedObserved)`** | `PlayerCutApp.swift:171-175` | Counter changes during pipeline completion (`PricingGate.recordFreeReelConsumed()` in `PipelineOrchestrator.swift:263-267`); paywall fullScreenCover can pop while user is in GameDetailView |
| F | **Audio session pin can collide with backgrounded audio apps** | `GameCaptureController.swift:73-84` | `.playAndRecord` with `.mixWithOthers, .defaultToSpeaker, .allowBluetooth` is logged-but-swallowed on failure; capture proceeds anyway, but with potentially-broken audio loudness sidecar |
| G | **`configure()` Phase 1 still throws on "no back camera" or "cannot add input/output"** | `GameCaptureController.swift:112-114, 149-191` | Surfaces `errorMessage` in CaptureView, preview never starts. Catastrophic on a hardware fault but legitimately unrecoverable |
| H | **Phase 2 recipe application runs on background queue without re-entrancy guard** | `GameCaptureController.swift:178-188` | If user taps record before `applyRecipeBestEffort` finishes, `startRecording` will call `applyRecipe` with `currentRecipe == nil` and the `if let` skips → recording proceeds at default format (graceful), but a second beginConfiguration nesting from the two paths could potentially race. No test exercises this. |
| I | **`AssistedTierView` sheet pops after first successful enrollment** | `PlayerCutApp.swift:124-127` | Modal between enrollment and record — extra tap to dismiss before the user can reach the capture screen |
| J | **`stop()` waits 300 ms then writes loudness JSON synchronously** | `GameCaptureController.swift:512-518` | If JSON encode of a long game's loudness array throws, `stopRecording` throws and the GameSession is never persisted — pipeline never runs. No test. |
| K | **`session.startRunning()` is dispatched async; `configured = true` flips before the session is actually running** | `CaptureView.swift:362-368`, `GameCaptureController.swift:163-170` | The 3 s watchdog catches this, but in the window between `configured=true` and `session.isRunning=true` the record button is enabled and tapping it triggers `startRecording` which calls `session.startRunning()` again. Idempotent per AVFoundation, but UNVERIFIED |
| L | **`MountDetector` always allocated as a `@State` even when off** | `CaptureView.swift:27` | The `CMMotionManager` instance is constructed but `start()` is only called when `autoStartEnabled` is true. Memory-only cost when off. Not a runtime risk; included for completeness |

**Over-engineering risks (CONVENIENCE or SUPPORTING that is also BLOCKING):**
None remaining as of `7b5f1a2`. The previous canonical example — `MountDetector` paired with `autoStartEnabled = true` default — was a CONVENIENCE+BLOCKING combination because the "DETECTING MOUNT" status sat in front of the manual record button visually and the controller's old `configure()` threw on recipe-resolution failure. Both legs were removed in commits `0310cd1` (recipe → best-effort) and `7b5f1a2` (auto-start off by default + recipe never throws + preview watchdog).

**High code volume relative to critical-path value (LOC-ranked):**
- `GameCaptureController.swift` 757 lines for CORE+SUPPORTING+CONVENIENCE bundled together. Recipe / thermal / scene / loudness / mount could plausibly live in separate files for clarity.
- `MetalPetalCompositor.swift` 570 lines, SUPPORTING, UNVERIFIED. Heavy GPU code with no fixture test.
- `ReelComposer.swift` 647 lines, CORE, UNVERIFIED on device.
- `EditPlanBuilder.swift` 460 lines, SUPPORTING, VERIFIED-SIM-ONLY for crop/ramp/style mapping but not the full plan generation path.
- `JerseyOCR.swift` 292 lines, SUPPORTING, UNVERIFIED (only the Levenshtein primitive is tested).

**Dead/stubbed code still in the build target:**
- `BeaconScanner.swift` (109 lines) — never referenced.
- `ByteTracker.swift` (79 lines) — never referenced.
- `PoseSignal.swift` (37 lines) — never referenced.
- `ThermalAndPowerMonitor.swift` (72 lines) — only self-reference.
- `Tuning/EvaluationHarness.swift` + `LabeledCorpus.swift` (396 lines combined) — never referenced from production code or tests.
- `PlayerEnrollment.beaconID: String?` field — stored, decoded, never set.
- `SettingsKeys.autoStopEnabled` UserDefault — toggle written by SettingsView, read by no one.

**Places where failure currently does NOT degrade gracefully:**
- `configure()` still throws on no-back-camera / can't-add-input / can't-add-output (`GameCaptureController.swift:112, 150, 156, 168, 189`). Legitimate hardware failures, but the only recovery is dismissing CaptureView.
- `stopRecording` throws if loudness-JSON encode fails (`GameCaptureController.swift:517`); GameSession never persisted, pipeline never runs.
- `AppCoordinator.didFinishRecording` calls `try? await store.upsert(game)` (per `PlayerCutApp.swift:70`) — silently swallows persistence failures. If the upsert fails, the game is enqueued for BG processing but never appears in the games strip.

---

## 3. Verified on device

**None.** No feature in the codebase has demonstrated correct end-to-end behavior on physical hardware that I can cite from a test, a log artifact, or a git commit.

The strongest device-side evidence available:
- Device **builds** succeed against the connected iPhone 14 Plus (commits `0310cd1`, `6bfec78`, `7b5f1a2`).
- Device **install** succeeds (`xcrun devicectl device install app` returned "App installed" in `7b5f1a2` and `6bfec78`).
- Device **launch** succeeded once (`xcrun devicectl device process launch` returned "Launched application" before commit `6bfec78`); the most recent launch attempt in `7b5f1a2` was rejected with `FBSOpenApplicationErrorDomain 7 ("Locked")`.
- A user report against build `6bfec78` stated the camera was "black and frozen on DETECTING MOUNT" — actively contradicting the assumption that the pre-fix capture flow worked.

That is the entire body of device evidence. Build + install + launch proves the binary loads. It does not prove any feature behaves correctly.

---

## 4. Compiles but unproven (UNVERIFIED features)

Every CORE feature except the two with passing sim-only tests:

- App entry + scene-phase brightness restore (#1)
- Welcome / terms gate (#2)
- Permissions primer gate (#3)
- Camera permission request + error banner (#6)
- Capture session setup Phase 1 (#7)
- Camera preview (#8) — actively reported broken on previous build
- 3-second preview watchdog (#9) — added today, never tripped
- Manual record button start/stop (#10)
- Pipeline orchestrator (#22)
- Stage 1 coarse detector (#23)
- Stage 2 player localizer (#24)
- ReelComposer end-to-end (#32)
- Photos library save (#37)
- GameDetailView player + Re-process / share / banner (#38)

Plus CORE features that have only sim-only proof:
- Player enrollment wizard — only "sheet opens" tested (#4)
- Root view — only "hero title visible" tested (#5)
- Game session persistence — relative-path resolver tested, not full upsert/restore cycle (#20)
- Highlight ranker — selection logic tested, never run against real Stage2 output (#29)

SUPPORTING / CONVENIENCE features that compile but have no on-device evidence:
- Thermal + battery live downgrade observers firing in practice (#12)
- Scene detection on a real frame (#13)
- Audio loudness sidecar values matching reality (#14)
- Brightness dim + persistent restore across kill (#15)
- Mount detection + auto-start countdown (#17)
- Reel length picker writing through to composition (#19)
- Background-task pipeline runner getting iOS BG time (#21)
- Jersey OCR window-level voting (#25)
- Vision pipeline + memory pressure handling (#26)
- Frame iterator (#27), pixel buffer pool (#28)
- MetalPetal compositor producing watchable frames (#31)
- Title / closing / lower-third rasterization (#34)
- Device-class perf profile driving real downgrades (#35)
- ETA panel rendering (#39)
- Compilation orchestrator (#40)
- Pricing paywall trigger (#41)
- Assisted-tier sheet (#42)
- BackgroundRefreshBanner (#44)
- Diagnostics view + export (#46)
- Design-system controls (#47)
- Music manifest read (#50; also bundled files are missing per Dependencies.md)

---

## Test coverage at a glance

Total tests (per `xcodebuild test`):
- **67 unit tests** in `PlayerCutTests` — all currently passing.
- **3 UI tests** in `PlayerCutUITests` — all currently passing. Coverage limited to: app launches, enrollment sheet opens, settings sheet opens.

Test classes and what they actually exercise:

| Test class | Tests | Exercises |
|------------|-------|-----------|
| `PlayerCutTests` | 1 | Smoke (1+1=2) |
| `LevenshteinTests` | 8 | String distance primitive |
| `HSVHistogramTests` | 5 | Histogram chi-squared distance |
| `HighlightRankerTests` | 13 | Ranker selection (diversity, bounds, chronological order, all 3 tiers, exceptional clip path, low-activity, empty input) |
| `DeviceCapabilitiesTests` | 18 | SoCTier mapping per identifier family, ideal recipe per tier, thermal/battery/low-power ladder, real-slow-mo flag, JSON round-trip, live-recipe collapse |
| `GameSessionRelativePathTests` | 4 | Documents-relative reel-URL migration |
| `EditPlanBuilderTests` | 5 | Crop keyframes stay in [0,1], anti-jitter, speed-curve continuity, chill suppresses ramps, style → LUT |
| `LUTFactoryTests` | 2 | LUT cube dimensions + endpoint preservation |
| `ETAEstimatorTests` | 3 | Cold-start ranged copy, envelope tightening, overdue label |
| `ComposerFallbackRegressionTests` | 3 | `composerUsedFallback` default-absent, can be affirmed false, `composerStageFailed` records counter + distribution |
| `PlayerCutUITests` | 3 | App launches (hero title), enrollment sheet opens, settings sheet opens |

What no test exercises (by design or omission):
- Live camera preview
- Recording start / stop on a real session
- Real Stage 1 / Stage 2 against a video fixture
- ReelComposer producing an actual MP4
- MetalPetal compositor rendering real frames
- Photos library save path
- GameDetailView playback or scenePhase transitions
- BackgroundProcessingV2 task scheduling
- Compilation, paywall, assisted-tier, mount-detection lifecycle
- The full enrollment wizard past the first sheet

---

*End of inventory. Findings are derived from the source tree at commit `7b5f1a2` and the git history through that commit. Where the source contradicted prior summaries, the source wins.*
