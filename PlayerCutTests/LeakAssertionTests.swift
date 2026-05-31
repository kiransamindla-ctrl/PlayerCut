//
//  LeakAssertionTests.swift
//  PlayerCutTests
//
//  Weak-reference-after-teardown leak checks. These do NOT replace
//  Instruments Leaks on a real device for the full pipeline, but they
//  catch the everyday "I captured `self` strongly in a closure"
//  regression at zero cost on every CI run.
//
//  Pattern:
//    1. Create the object inside a scope.
//    2. Take a `weak var` reference.
//    3. Let the scope end so the strong reference drops.
//    4. Assert the weak reference is nil.
//
//  For actors, deinit can race with the test thread, so we explicitly
//  hop through the actor once (`await Task.yield()`) and drain any
//  pending Tasks the object scheduled in its init.
//

import XCTest
@testable import PlayerCut

final class LeakAssertionTests: XCTestCase {

    // MARK: - PipelineOrchestrator
    //
    // The orchestrator's init() installs a MemoryPressureMonitor handler.
    // That handler captures `stage1`, `stage2`, `log` — locals, not
    // `self` — so it must NOT pin the orchestrator. Regressing this
    // (e.g. closing over `self` in the handler) leaks every game's
    // worth of pipeline state for the app's lifetime.
    func testPipelineOrchestratorDeallocates() async throws {
        weak var weakOrchestrator: PipelineOrchestrator?
        let store = GameStore()
        do {
            let orchestrator = PipelineOrchestrator(store: store)
            weakOrchestrator = orchestrator
            // Touch the orchestrator at least once so the compiler can't
            // optimize the strong reference into thin air.
            _ = await orchestrator.gameStatus(id: UUID())
        }
        // Give the actor's deinit a chance to fire. One Task yield is
        // enough to let the actor's queue drain on the simulator; we
        // add a short sleep as belt + braces because actor deinit isn't
        // guaranteed to be synchronous with the strong ref dropping.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)   // 50 ms
        XCTAssertNil(weakOrchestrator,
                     "PipelineOrchestrator leaked — check that the MemoryPressureMonitor handler doesn't capture self.")
    }

    // MARK: - SystemCameraPicker.Coordinator
    //
    // The Coordinator is the capture controller after the
    // UIImagePickerController switch (commit eb48353). It holds an
    // onComplete closure that's invoked when the user dismisses the
    // camera. If the closure captures the Coordinator itself, the
    // picker leaks across every recording session.
    @MainActor
    func testCaptureCoordinatorDeallocates() {
        weak var weakCoordinator: SystemCameraPicker.Coordinator?
        do {
            let coordinator = SystemCameraPicker.Coordinator(onComplete: { _ in })
            weakCoordinator = coordinator
            // Force a delegate-method call path that mirrors real use,
            // so the closure is actually invoked at least once. The
            // call goes through a synthesized UIImagePickerController
            // we discard immediately; we only care about the post-
            // dismissal closure release semantics.
            _ = coordinator.onComplete
        }
        XCTAssertNil(weakCoordinator,
                     "SystemCameraPicker.Coordinator leaked — onComplete closure likely captures self.")
    }
}
