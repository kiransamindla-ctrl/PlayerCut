# Background Tasks — The Operations Manual

This document is the missing piece of Apple's BackgroundTasks docs: how to
actually verify the thing works on a real device.

## Why this is hard

`BGProcessingTask` requests are *advisory*. iOS decides:

- whether to grant the task at all (battery state, charging, thermal, user
  habits with your app, screen time settings)
- how much wall-clock time to give you (a few minutes typically)
- when to expire your task (it can revoke at any time)

The docs do not describe the heuristics, and they change between iOS
versions. You will not learn this from the simulator. You must test on a
device that has been used normally for at least 24 hours, ideally a few
days.

## The startup checklist

Before debugging, verify the four things that silently break BG tasks:

1. **Info.plist** must contain:
   ```xml
   <key>UIBackgroundModes</key>
   <array>
       <string>processing</string>
       <string>fetch</string>
   </array>
   <key>BGTaskSchedulerPermittedIdentifiers</key>
   <array>
       <string>com.playercut.app.process-game</string>
       <string>com.playercut.app.refresh</string>
   </array>
   ```

2. **Capabilities ▸ Background Modes** must have **Background processing**
   AND **Background fetch** checked.

3. **Settings ▸ General ▸ Background App Refresh** must be ON for the device
   AND for your app individually. If a user has it off, BG tasks never run.

4. **Low Power Mode** must be off. iOS aggressively defers BG processing
   under Low Power Mode.

## How to actually trigger a BG task in development

There is no "trigger BG task now" button in Xcode. Use the LLDB debugger:

1. Run your app on device from Xcode.
2. The app submits a `BGProcessingTaskRequest`.
3. Press the home button — the app moves to background.
4. In Xcode, click the Pause button on the running app.
5. In the LLDB console, type one of:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.playercut.app.process-game"]
   ```

   or, to simulate expiration:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.playercut.app.process-game"]
   ```

6. Click Continue in Xcode. Your task handler will fire.

`_simulateLaunchForTaskWithIdentifier:` is a private API but is the
canonical way Apple documents on developer.apple.com for testing.

## What to log

Every state change, with OSLog, in the `com.playercut.app` subsystem,
`BG` category. Use `Console.app` on your Mac (not Xcode console) and
filter by subsystem to see logs from the past several days even when the
app wasn't connected to Xcode.

The events to log:

- Submission of every `BGTaskRequest` (timestamp + earliestBeginDate)
- Successful registration on launch
- Every invocation of your task handler
- Every expiration
- Pipeline progress (Stage 1 start, end, etc.)
- Notification posted

Without these logs, you cannot tell whether iOS is granting time or
silently deferring.

## The six failure modes you'll hit

### 1. "Task never fires in production"

Most common cause: Background App Refresh disabled, or you submitted the
task from a context where iOS is suspending you immediately. Submit the
task BEFORE entering background, not after.

### 2. "Task fires but completes in 5 seconds with nothing done"

You forgot to set `task.expirationHandler` and iOS killed you immediately
after the handler returned synchronously. The handler must capture the
task and complete it asynchronously, OR Swift Concurrency was not waiting
on your Task.

### 3. "Task is granted but runs out of time mid-Stage-2"

Expected. Persist Stage 1 results to disk before starting Stage 2. Your
expiration handler cancels the running Task (which respects cooperative
cancellation in our actor-based pipeline). Next run picks up at Stage 2.

### 4. "Multiple tasks queued, only first one runs"

The next request is re-submitted from `handleProcessingTask` after each
completion. Verify that path with logs.

### 5. "Works on dev device, not on TestFlight"

Almost always: TestFlight users haven't been "engaging" with the app
enough for iOS's heuristics to grant BG time. The foreground-fallback
runner is your salvation. Most users will open the app within an hour
of recording a game; the fallback completes the work then.

### 6. "Works in iOS 17, broken in iOS 18"

Apple changes the heuristics every release. The foreground fallback is
your insurance. Treat BG as optional acceleration, not a requirement.

## The acceptance test before shipping

For each of these, use a fresh test device that has been used normally
for 48+ hours (BG heuristics need history):

- [ ] Record a 60-minute game, plug in to charge, lock the phone, leave
      overnight. Check Console.app in the morning — BG task fired and
      completed.
- [ ] Same as above, but unplugged. Expected: BG task does NOT fire
      (because `requiresExternalPower = true`). Foreground fallback runs
      next time you open the app.
- [ ] Record three games in a row, plug in. All three should process
      sequentially.
- [ ] Record a game, kill the app from app-switcher (do not just
      background it). Open the app later. Foreground fallback should
      pick up and process.
- [ ] Record a game, force a crash (assertion in the pipeline) midway
      through Stage 2. Open the app again. Pipeline should resume from
      Stage 2 using the persisted Stage 1 result.
- [ ] Lock-screen notification fires when reel is ready, taps deep-link
      to the reel preview.

## What you must monitor in production

Add a single counter to your local analytics for each:

- `bg_task_submitted` — how often you ask
- `bg_task_handled` — how often iOS grants
- `bg_task_expired` — how often iOS reclaims mid-run
- `foreground_fallback_completed` — how often the fallback saved you

The ratio of `handled` to `submitted` tells you whether iOS likes your app.
The ratio of `foreground_fallback_completed` to `bg_task_handled` tells
you whether you actually need BG at all. (Spoiler: many shipping consumer
apps find foreground fallback handles 80%+ of the load and BG tasks
handle the residual.)
