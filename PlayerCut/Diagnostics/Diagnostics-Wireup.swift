//
//  Diagnostics-Wireup.swift
//  PlayerCut/Diagnostics
//
//  Reference patches showing where DiagnosticsStore should be called from
//  the existing modules. Keep these calls one-liners; the store handles
//  debouncing and persistence.
//

/*
 ────────────────────────────────────────────────────────────────────────
 PipelineOrchestrator.run(...)
 ────────────────────────────────────────────────────────────────────────

 Wrap each stage with timing:

     let stage1Start = Date()
     let stage1Result = try await self.stage1.detect(in: game)
     let stage1Duration = Date().timeIntervalSince(stage1Start)
     await DiagnosticsStore.shared.recordDuration(.stage1,
                                                  seconds: stage1Duration)
     // ... same for stage2, ranking, composition

 At end of successful run:

     await DiagnosticsStore.shared.increment(.reelsCompleted)
     await DiagnosticsStore.shared.recordDuration(
         .totalPipeline,
         seconds: Date().timeIntervalSince(pipelineStart))
     await DiagnosticsStore.shared.recordDailyEvent(.appOpened)
     await DiagnosticsStore.shared.recordEnum(.sport, value: game.sport)

 In error paths:

     await DiagnosticsStore.shared.increment(.reelsFailed)
     // Categorize the error WITHOUT logging text:
     if case .captureFailed = error {
         await DiagnosticsStore.shared.increment(.errorCaptureFailed)
     } else if case .compositionFailed = error {
         await DiagnosticsStore.shared.increment(.errorComposeFailed)
     } else {
         await DiagnosticsStore.shared.increment(.errorPipelineFailed)
     }

 If pipeline started with persisted Stage 1 already on disk:

     await DiagnosticsStore.shared.increment(.reelsRetriedFromResume)


 ────────────────────────────────────────────────────────────────────────
 BackgroundProcessingV2 — every BG state transition
 ────────────────────────────────────────────────────────────────────────

 In scheduleAllPendingTasks(), after successful submit():
     Task { await DiagnosticsStore.shared.increment(.bgTaskSubmitted) }

 In handleProcessingTask, at top:
     Task { await DiagnosticsStore.shared.increment(.bgTaskHandled) }

 In expirationHandler:
     Task { await DiagnosticsStore.shared.increment(.bgTaskExpired) }

 In foregroundRunner, after a game completes:
     Task { await DiagnosticsStore.shared.increment(.foregroundFallbackCompleted) }


 ────────────────────────────────────────────────────────────────────────
 GameCaptureController — capture lifecycle
 ────────────────────────────────────────────────────────────────────────

 In stopRecording(), before returning:
     await DiagnosticsStore.shared.increment(.gamesRecorded)
     await DiagnosticsStore.shared.recordDuration(
         .captureSession,
         seconds: Date().timeIntervalSince(game.startedAt))

 If you observe AVCaptureSessionWasInterrupted:
     await DiagnosticsStore.shared.increment(.captureInterruptions)


 ────────────────────────────────────────────────────────────────────────
 EnrollmentViewModel.save(...)
 ────────────────────────────────────────────────────────────────────────

 On success:
     await DiagnosticsStore.shared.recordDailyEvent(.enrollmentCompleted)


 ────────────────────────────────────────────────────────────────────────
 ReelComposer — successful share
 ────────────────────────────────────────────────────────────────────────

 When the user actually taps share on a reel (not just opens it):
     await DiagnosticsStore.shared.recordDailyEvent(.reelShared)


 ────────────────────────────────────────────────────────────────────────
 What to NEVER do
 ────────────────────────────────────────────────────────────────────────

 ❌ Record absolute timestamps (`Date().timeIntervalSince1970`).
    Day-bucketed only. The dailyEvents API enforces this.

 ❌ Record names, file paths, video URLs, jersey numbers, or sport-team
    names. The typed CounterKey/EnumKey APIs make this hard to do by
    accident — adding a new event requires adding it to the enum.

 ❌ Send anything over the network, ever. There is no networking code
    in DiagnosticsStore. If a future PR adds URLSession code under
    Diagnostics/, reject it.

 ❌ Log error messages or stack traces. We have OSLog for that, locally,
    not in shareable diagnostics. If a user shares diagnostics with a
    crash log, that's their explicit choice — but our diagnostics file
    must contain only counters and durations.
 */
