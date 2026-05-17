# PlayerCut — Claude Code Handoff

## Step 1: Install Claude Code on Mac

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Or via npm:
```bash
npm install -g @anthropic-ai/claude-code
```

Then in any terminal:
```bash
claude
```
Sign in when prompted.

## Step 2: Get the project

Download `PlayerCut-buildable.zip` (next message), unzip, `cd` into it.

```bash
unzip PlayerCut-buildable.zip
cd PlayerCut-build
```

## Step 3: Bootstrap (one command)

```bash
./bootstrap.sh
```

This:
- Installs XcodeGen via Homebrew if missing
- Generates `PlayerCut.xcodeproj`
- Creates the test target stub

If you don't have Homebrew yet: `https://brew.sh` then re-run.

## Step 4: Open in Xcode

```bash
open PlayerCut.xcodeproj
```

Set your Team under PlayerCut target → Signing & Capabilities.

## Step 5: Start Claude Code in the project directory

In a new terminal:
```bash
cd PlayerCut-build
claude
```

## Step 6: First prompts to run (copy these into Claude Code)

### Prompt 1 — compile clean

```
Build the project for an iOS Simulator (iPhone 15) and fix any compile
errors you find. Don't change algorithm behavior — only fix syntax,
imports, deprecated APIs, missing protocol conformances, and similar
build-blocking issues. Run:

  xcodebuild -project PlayerCut.xcodeproj -scheme PlayerCut \
    -destination 'platform=iOS Simulator,name=iPhone 15' build

After each fix, re-run until the build succeeds.
```

### Prompt 2 — pure-logic tests

```
Write XCTest unit tests under PlayerCutTests/ for the pure-logic pieces:

1. Levenshtein distance (used by JerseyOCR) — extract it from
   Stage2PlayerLocalizer.swift and JerseyOCR.swift into a new file
   PlayerCut/Utilities/StringDistance.swift as a free function, then
   test it.

2. HSV histogram chi-squared distance (CoreModels.swift HSVHistogram).
   Test identical vs different histograms produce expected distances.

3. HighlightRanker.selectClips — feed it synthetic ScoredMoment arrays
   and verify diversity rule (no two clips within 30s), clip count
   bounds, ordering.

Run the tests:

  xcodebuild test -project PlayerCut.xcodeproj -scheme PlayerCut \
    -destination 'platform=iOS Simulator,name=iPhone 15'

Fix any failures.
```

### Prompt 3 — wire perf improvements

```
Integrate the performance modules into Stage 1 and Stage 2:

1. Replace AVAssetImageGenerator usage in Stage1CoarseDetector with
   FrameIterator for the optical flow loop. Use PixelBufferPool for
   the 320x180 proxy buffers.

2. In Stage2PlayerLocalizer, replace per-window AVAssetImageGenerator
   with FrameIterator, and route all Vision calls through
   VisionPipeline actor.

3. Wire MemoryPressureMonitor in PipelineOrchestrator so that on
   .critical events, pixel pools flush and Stage 2 pauses for 30s.

Build after each change. Don't break existing call sites — adapt them.
```

### Prompt 4 — wire diagnostics

```
Follow Diagnostics-Wireup.swift exactly. Add the documented
DiagnosticsStore calls to:
- PipelineOrchestrator (durations + reel outcomes)
- BackgroundProcessingV2 (BG task counters)
- GameCaptureController (capture lifecycle)
- EnrollmentViewModel (enrollment completed)

Use Task { await ... } from non-async contexts. Build after.
```

### Prompt 5 — wire JerseyOCR

```
Apply the patch documented in
PlayerCut/Vision/Stage2-JerseyOCR-Integration.swift to
Stage2PlayerLocalizer:

1. Add `let ocr = JerseyOCR()` and `var ocrFrameResults` accumulator
   to processWindow.
2. Replace per-frame scoreJerseyNumber with ocr.recognize accumulation.
3. After the frame loop, call ocr.aggregate to get window-level
   numberScore.
4. When ocrWindowResult.frameCount < 3, drop jersey weight from 0.5
   to 0.2 and redistribute to color (0.5) and face (0.3).

Build after.
```

### Prompt 6 — run on device

```
I have an iPhone connected. Help me:
1. Verify the device shows up in `xcrun devicectl list devices`
2. Build and run on the device
3. Walk through the first launch: enrollment → start a short test
   recording → stop → watch the pipeline run
4. Show me the OSLog output filtered to com.playercut.app
```

## What Claude Code can do that this chat can't

- Run `xcodebuild` and read errors
- Open files in Xcode-compatible ways and edit them
- Run on simulator and inspect logs
- Iterate on compile errors until green
- Read your actual device logs via `log stream`
- Run XCTest and report failures
- Use git locally

## When you hit problems

Paste the exact error into Claude Code. It has the full project context
and can fix-and-rebuild without you switching tools.

## Updating the checklist

Tell me here what got checked off and I'll update
`PlayerCut-Checklist.md`.
