# Phase 3 Remaining P2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Burn down the remaining review-12 P2 deltas after the watcher reducer and reseed/master contract phases.

**Architecture:** This is a conventional delta wave, not a redesign. Keep the existing OBSClient / OBSController / BroadcastController state machines intact and extend the already-reviewed mechanisms: one connect deadline, one outbound send chain, epoch/stamp guards, and the existing deferred reconcile latch. For import, make enumeration failure an explicit source error instead of converting it to an empty stream.

**Tech Stack:** Swift 5.10 package, XCTest, LiveAstroCore.

## Global Constraints

- Work on branch `feature/phase3-remaining-p2` in `/Users/pauldavis/liveastro-studio/.worktrees/phase3-remaining-p2`.
- TDD is mandatory: write a failing test and observe it fail before production edits.
- Do not run overlapping SwiftPM builds/tests in the same worktree.
- Do not rewrite OBS/watch/import architecture; Phase 3 is deltas only.
- Transport-dial timeout extends the existing OBSClient handshake watchdog window to open before `socket.connect`; do not add a second timeout mechanism.
- Deferred-reconcile work starts by enumerating existing owner-settlement sites; cold2 already settled the six stop-owner returns, so do not churn reviewed lines unless a missing site is proven.
- Final gate includes focused tests, full suite, release build, test-build warning audit, cold/code-quality review, and clean tree.

---

## Files and Responsibilities

- `Sources/LiveAstroCore/OBS/OBSClient.swift`: connect deadline, send-chain reset on disconnect/reconnect.
- `Sources/LiveAstroCore/OBS/OBSController.swift`: scene-list stamping, event-loop teardown/client leak fallback.
- `Sources/LiveAstroCore/OBS/BroadcastController.swift`: deferred-reconcile missing-site sweep only.
- `Sources/LiveAstroCore/Sources/FolderFrameSource.swift`: import enumeration error storage/surfacing.
- `Tests/LiveAstroCoreTests/MockOBSSocket.swift`: test knobs for parked connect and leak/close assertions.
- `Tests/LiveAstroCoreTests/OBSClientTests.swift`: OBSClient timeout/send-chain regression tests.
- `Tests/LiveAstroCoreTests/OBSControllerTests.swift`: scene stamping and leak/teardown regression tests.
- `Tests/LiveAstroCoreTests/BroadcastControllerTests.swift`: deferred reconcile missing-site regression, if enumeration proves one.
- `Tests/LiveAstroCoreTests/FolderFrameSourceTests.swift`: unreadable/missing import folder surfaces as error/log instead of empty success.
- Named warning files: `PerformanceTests.swift`, `RejectionEngineTests.swift`, `ReplayServiceTests.swift`, `DebayerRCDTests.swift`, `BackgroundExtractionTests.swift`, `BroadcastControllerTests.swift`, `StackFileWatcherTests.swift`.

---

### Task 1: OBSClient connect deadline and send-chain reset

**Files:**
- Modify: `Sources/LiveAstroCore/OBS/OBSClient.swift`
- Modify: `Tests/LiveAstroCoreTests/MockOBSSocket.swift`
- Test: `Tests/LiveAstroCoreTests/OBSClientTests.swift`

**Interfaces:**
- Produces: `MockOBSSocket.parkConnect: Bool`, `MockOBSSocket.connectStartedCount`, `MockOBSSocket.releaseParkedConnects()`.
- Produces: OBSClient `connect(url:password:)` throws `.timeout` when the transport connect itself exceeds `handshakeTimeout`.
- Produces: OBSClient `disconnect()` abandons the outbound send chain so a reconnect starts from a fresh chain.

- [ ] **Step 1: Add failing transport-connect timeout test**

Add to `OBSClientTests`:

```swift
func testConnectTimeoutCoversTransportConnectBeforeHello() async throws {
    let mock = MockOBSSocket()
    mock.parkConnect = true
    let client = OBSClient(socket: mock, requestTimeout: 0.05, handshakeTimeout: 0.05)

    do {
        try await client.connect(url: url, password: nil)
        XCTFail("parked transport connect must time out")
    } catch OBSClient.OBSError.timeout {
        XCTAssertEqual(mock.connectStartedCount, 1)
        XCTAssertEqual(mock.closeCount, 1, "timeout closes the transport attempt")
    } catch {
        XCTFail("expected OBSClient timeout, got \(error)")
    }
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter OBSClientTests/testConnectTimeoutCoversTransportConnectBeforeHello`

Expected: test hangs until XCTest timeout or fails because the current watchdog starts only after `socket.connect` returns.

- [ ] **Step 3: Implement connect deadline as one mechanism**

Add `connectTimedOut` state next to `handshakeTimedOut`, start the watchdog before `socket.connect`, and have one expiry function close the socket while either transport connect or handshake is in flight:

```swift
private var connectAttemptFinished = true
private var connectTimedOut = false

public func connect(url: URL, password: String?) async throws {
    connectTimedOut = false
    handshakeTimedOut = false
    connectAttemptFinished = false
    let watchdog = Task { [weak self, handshakeTimeout] in
        try? await Task.sleep(nanoseconds: UInt64(handshakeTimeout * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await self?.expireConnectAttempt()
    }
    defer {
        watchdog.cancel()
        connectAttemptFinished = true
    }
    do {
        try await socket.connect(url: url)
        try await performHandshake(password: password)
    } catch {
        socket.close()
        throw (connectTimedOut || handshakeTimedOut) ? OBSError.timeout : error
    }
    connected = true
    connectAttemptFinished = true
    startReceiveLoop()
}

private func expireConnectAttempt() {
    guard !connected, !connectAttemptFinished else { return }
    connectTimedOut = true
    handshakeTimedOut = true
    socket.close()
}
```

Adjust names to avoid duplicate `socket.close()` side effects if needed, but keep one deadline and `.timeout` mapping.

- [ ] **Step 4: Add failing send-chain reset test**

Add to `OBSClientTests`:

```swift
func testDisconnectAbandonsParkedSendChainSoReconnectRequestsAreNotPoisoned() async throws {
    let mock = MockOBSSocket()
    let client = OBSClient(socket: mock, requestTimeout: 0.05)

    mock.enqueueInbound(helloFrame())
    mock.replyToLastSent { [identifiedFrame] sent in sent.contains("\"op\":1") ? identifiedFrame : nil }
    try await client.connect(url: url, password: nil)

    mock.parkSendsMatching = { $0.contains("\"requestType\":\"GetVersion\"") }
    let poisoned = Task { try? await client.request("GetVersion", data: nil) }
    while mock.parkedSendCount == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
    await client.disconnect()

    mock.parkSendsMatching = nil
    mock.enqueueInbound(helloFrame())
    mock.replyToLastSent { [identifiedFrame] sent in
        if sent.contains("\"op\":1") { return identifiedFrame }
        if sent.contains("\"requestType\":\"GetStats\"") {
            return self.responseFrame(requestId: self.requestId(fromSent: sent),
                                      requestType: "GetStats", ok: true, code: 100,
                                      responseData: ["ok": true])
        }
        return nil
    }
    try await client.connect(url: url, password: nil)
    let response = try await client.request("GetStats", data: nil)
    XCTAssertEqual(response["ok"] as? Bool, true)
    _ = await poisoned.value
}
```

- [ ] **Step 5: Verify red**

Run: `swift test --filter OBSClientTests/testDisconnectAbandonsParkedSendChainSoReconnectRequestsAreNotPoisoned`

Expected: fail/timeout because the new request awaits the stale send-chain tail.

- [ ] **Step 6: Implement send-chain abandonment**

In `disconnect()` / `failAll(error:)`, cancel and nil `sendChainTail` after cancelling/removing `sendTasks`:

```swift
sendChainTail?.cancel()
sendChainTail = nil
```

Ensure reconnect begins with no dependency on the stale tail.

- [ ] **Step 7: Verify green and commit**

Run:

```bash
swift test --filter OBSClientTests
git add Sources/LiveAstroCore/OBS/OBSClient.swift Tests/LiveAstroCoreTests/MockOBSSocket.swift Tests/LiveAstroCoreTests/OBSClientTests.swift
git commit -m "fix: bound obs connect and reset send chain"
```

Expected: OBSClientTests pass.

---

### Task 2: Import enumeration errors are honest

**Files:**
- Modify: `Sources/LiveAstroCore/Sources/FolderFrameSource.swift`
- Test: `Tests/LiveAstroCoreTests/FolderFrameSourceTests.swift`

**Interfaces:**
- Produces: `FolderFrameSourceError.enumerationFailed(String)` or equivalent Equatable case.
- Produces: import mode `start()` throws when the initial folder enumeration fails.
- Produces: pull-time enumeration failures log and end the stream only after surfacing the reason.

- [ ] **Step 1: Add failing import enumeration test**

Add to `FolderFrameSourceTests`:

```swift
func testImportModeMissingFolderThrowsInsteadOfSuccessfulEmptyImport() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = FolderFrameSource(folder: dir, mode: .importOnce)

    XCTAssertThrowsError(try source.start()) { error in
        guard case FolderFrameSourceError.enumerationFailed = error else {
            return XCTFail("expected enumeration failure, got \(error)")
        }
    }
    XCTAssertEqual(source.totalCount, nil)
}
```

If `totalCount` must remain nonoptional for API compatibility, assert `0` but require the thrown error.

- [ ] **Step 2: Verify red**

Run: `swift test --filter FolderFrameSourceTests/testImportModeMissingFolderThrowsInsteadOfSuccessfulEmptyImport`

Expected: current code treats missing/unreadable folder as empty and does not throw.

- [ ] **Step 3: Implement explicit enumeration failure**

Change `ImportCursor` to store `snapshotError: Error?`, make `snapshotIfNeeded()` throw, and make `start()` propagate it:

```swift
func snapshotIfNeeded() throws {
    try lock.withLock { try snapshotLocked() }
}

private func snapshotLocked() throws {
    guard files == nil, snapshotError == nil else {
        if let snapshotError { throw snapshotError }
        return
    }
    do {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        files = ...
    } catch {
        snapshotError = error
        throw error
    }
}
```

Wrap as `FolderFrameSourceError.enumerationFailed(folder.lastPathComponent)` if the enum must stay Equatable.

- [ ] **Step 4: Preserve pull semantics**

In the AsyncStream unfolding closure, when `cursor.next()` throws enumeration failure, log `"Import enumeration failed (<folder>): <error>"` and return nil. `start()` should catch initial enumeration failures before a session can finalize as successful empty.

- [ ] **Step 5: Verify green and commit**

Run:

```bash
swift test --filter FolderFrameSourceTests
git add Sources/LiveAstroCore/Sources/FolderFrameSource.swift Tests/LiveAstroCoreTests/FolderFrameSourceTests.swift
git commit -m "fix: surface import enumeration failures"
```

Expected: FolderFrameSourceTests pass.

---

### Task 3: OBSController scene stamping and receive-loop teardown

**Files:**
- Modify: `Sources/LiveAstroCore/OBS/OBSController.swift`
- Test: `Tests/LiveAstroCoreTests/OBSControllerTests.swift`

**Interfaces:**
- Produces: scene-list response stamping for both `sceneNames` and `currentScene`.
- Produces: event-loop termination releases `client` and cancels `eventsTask` on current-epoch unexpected close.
- Produces: controller deinit/teardown closes any current client.

- [ ] **Step 1: Add failing scene-list stamp test**

Add to `OBSControllerTests`:

```swift
func testSeedSceneListAnswerNeverOverwritesNewerSceneListEvent() async {
    let h = Harness()
    h.server.parkTypes.insert("GetSceneList")
    let task = Task { await h.controller.connect(host: "localhost", port: 4455, password: nil) }
    await waitUntil { h.server.parked.contains { $0.type == "GetSceneList" } }

    h.mock.enqueueInbound(eventFrame(type: "SceneListChanged", data: [:]))
    h.server.scenes = ["New A", "New B"]
    h.server.currentScene = "New B"
    h.controller.refreshScenes()

    let parked = h.server.parked.first { $0.type == "GetSceneList" }!
    h.mock.enqueueInbound(responseFrame(requestId: parked.id, requestType: "GetSceneList",
                                        ok: true, responseData: [
                                            "scenes": [["sceneName": "Old"]],
                                            "currentProgramSceneName": "Old"
                                        ]))
    _ = await task.value
    XCTAssertNotEqual(h.controller.sceneNames, ["Old"])
    XCTAssertNotEqual(h.controller.currentScene, "Old")
}
```

Adjust to existing `OBSControllerTests` harness names; the behavior is the key: an older scene-list response must not overwrite a newer scene-list refresh/event.

- [ ] **Step 2: Verify red**

Run: `swift test --filter OBSControllerTests/testSeedSceneListAnswerNeverOverwritesNewerSceneListEvent`

Expected: current code stamps only current scene, not the list.

- [ ] **Step 3: Implement scene-list stamping**

Capture `sceneStamp` before `GetSceneList`; apply both `sceneNames` and `currentScene` only if `sceneStamp == sceneStateVersion`. If the stamp changed, log and leave both fields untouched.

- [ ] **Step 4: Add failing receive-loop teardown test**

Add to `OBSControllerTests`:

```swift
func testReceiveLoopFailureClearsCurrentClientAndAllowsFreshConnect() async {
    let h = Harness()
    XCTAssertTrue(await h.controller.connect(host: "localhost", port: 4455, password: nil))
    h.mock.finishWithError(OBSSocketError.notConnected)
    await waitUntil { h.controller.state == .disconnected }

    let second = MockOBSSocket()
    h.installNextSocket(second)
    second.enqueueInbound(helloFrame())
    second.replyToLastSent { sent in sent.contains("\"op\":1") ? identifiedFrame : nil }

    XCTAssertTrue(await h.controller.connect(host: "localhost", port: 4455, password: nil))
    XCTAssertEqual(h.controller.state, .connected)
}
```

If the existing harness cannot swap sockets, add a minimal local controller using `makeSocket` over an array of sockets.

- [ ] **Step 5: Verify red**

Run: `swift test --filter OBSControllerTests/testReceiveLoopFailureClearsCurrentClientAndAllowsFreshConnect`

Expected: fail if stale `client` / task cleanup blocks or leaks current connection.

- [ ] **Step 6: Implement teardown fallback**

In the event-stream fallthrough path, for current epoch:

```swift
self.log("connection lost — converging to .disconnected")
self.eventsTask = nil
self.client = nil
self.state = .disconnected
self.connectionEpoch += 1
self.onConnectionLost?()
Task { await client.disconnect() }
```

Keep deliberate `disconnect()` behavior unchanged.

- [ ] **Step 7: Verify green and commit**

Run:

```bash
swift test --filter OBSControllerTests
git add Sources/LiveAstroCore/OBS/OBSController.swift Tests/LiveAstroCoreTests/OBSControllerTests.swift
git commit -m "fix: stamp obs scene state and tear down lost clients"
```

Expected: OBSControllerTests pass.

---

### Task 4: Deferred reconcile missing-site sweep

**Files:**
- Modify: `Sources/LiveAstroCore/OBS/BroadcastController.swift` only if a missing site is proven.
- Test: `Tests/LiveAstroCoreTests/BroadcastControllerTests.swift` if a missing site is proven.

**Interfaces:**
- Produces: a short private audit note in `.superpowers/sdd/task-4-report.md` enumerating every owner-settlement/early-return site and whether it already calls `runDeferredReconcileIfNeeded()`.

- [ ] **Step 1: Enumerate settlement sites**

Run:

```bash
rg -n "return|settleAfterStop|settleStaleStart|runDeferredReconcileIfNeeded|reconcileWhenOwnerSettles|guard gen == broadcastGeneration|handleConnectionLoss" Sources/LiveAstroCore/OBS/BroadcastController.swift
```

Write the checked list to `.superpowers/sdd/task-4-report.md` as private ledger evidence.

- [ ] **Step 2: If a missing stale-owner return exists, write the failing test**

The test shape:

```swift
func testDeferredReconcileRunsAfterNamedStaleOwnerReturn() async {
    let h = await makeHarness()
    // Drive state to .stopping or appStartInFlight, park the owner, inject a restart/output event
    // that sets reconcileWhenOwnerSettles, then stale the owner and let it return.
    // Expected: deferred pass runs and adopts newest OBS truth (.live or .stopUnconfirmed).
}
```

Use the exact missing site from Step 1; do not invent a generic test.

- [ ] **Step 3: Verify red**

Run the single new BroadcastController test. Expected: state remains stale because the deferred reconcile latch is not drained.

- [ ] **Step 4: Implement one-line settlement**

At the proven stale return site, call `runDeferredReconcileIfNeeded()` in the same pattern as the reviewed stop-owner sites:

```swift
guard gen == broadcastGeneration else {
    runDeferredReconcileIfNeeded()
    return
}
```

- [ ] **Step 5: Verify and commit**

Run:

```bash
swift test --filter BroadcastControllerTests
git add Sources/LiveAstroCore/OBS/BroadcastController.swift Tests/LiveAstroCoreTests/BroadcastControllerTests.swift
git commit -m "fix: drain deferred obs reconcile after stale owner"
```

If no missing site is found, leave the private report uncommitted/ignored and record the audit outcome in the final evidence instead of creating a code commit:

```bash
git status --short
```

---

### Task 5: Debug test-build warning cleanup and final verification

**Files:**
- Modify warning-only test files named by the Phase 2 audit:
  - `Tests/LiveAstroCoreTests/RejectionEngineTests.swift`
  - `Tests/LiveAstroCoreTests/PerformanceTests.swift`
  - `Tests/LiveAstroCoreTests/ReplayServiceTests.swift`
  - `Tests/LiveAstroCoreTests/BackgroundExtractionTests.swift`
  - `Tests/LiveAstroCoreTests/BroadcastControllerTests.swift`
  - `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`
  - `Tests/LiveAstroCoreTests/DebayerRCDTests.swift`

**Interfaces:**
- Produces: no debug test-build warnings from the named files.
- Produces: final review package and final branch evidence.

- [ ] **Step 1: Run warning audit baseline**

Run:

```bash
swift test --filter StackEngineFinalizationStateTests -Xswiftc -DPHASE3_WARNING_AUDIT
```

Expected before cleanup: inherited warnings in the named test files.

- [ ] **Step 2: Apply mechanical warning fixes**

Examples:

```swift
for _ in 0..<12 { ... }              // RejectionEngineTests unused i
let _ = try buildSessionDir(...)     // ReplayServiceTests unused dir, or remove call if unnecessary
let w = img.width, h = img.height    // remove unused plane
weak let controller = h!.controller  // if accepted by Swift; otherwise keep weak var and add a read mutation-free suppression pattern
@preconcurrency @testable import LiveAstroCore // StackFileWatcherTests if this suppresses only test warning
```

For `PerformanceTests`, wrap skipped debug code so unreachable optimized-only code is inside `#else`:

```swift
#if DEBUG
throw XCTSkip(...)
#else
let width = ...
...
#endif
```

- [ ] **Step 3: Verify warning cleanup**

Run the same warning audit command. Expected: no warnings from the named files. If unrelated warnings remain, list them explicitly.

- [ ] **Step 4: Run final gates**

Run, sequentially:

```bash
swift test --filter 'OBSClientTests|OBSControllerTests|BroadcastControllerTests|FolderFrameSourceTests'
swift test
swift build -c release
git diff --check
git status --short
```

Expected: tests pass, release build passes, diff check clean.

- [ ] **Step 5: Final reviews**

Create review package from `main...HEAD`, then run two final reviews:

- cold correctness: OBS lifecycle/timeout/reconcile/import honesty
- code quality: maintainability/API/test discipline

Fix Critical/Important findings red-first. Record accepted Minor/Theoretical findings in `.superpowers/sdd/progress.md`.

- [ ] **Step 6: Commit reports and stop for merge**

Commit any warning/report updates, update `/Users/pauldavis/liveastro-studio/.superpowers/sdd/progress.md` with exact evidence, and stop for merge/push authorization.

---

## Self-Review

- Spec coverage: every item in §4 is mapped: transport connect timeout (Task 1), send-chain abandon on reconnect (Task 1), import enumeration errors (Task 2), scene-list stamping (Task 3), stale-stop/deferred reconcile site (Task 4), receive-loop/client leak fallback (Task 3), debug test-build warnings (Task 5).
- Placeholder scan: no TBD/TODO/fill-in placeholders; Task 4 deliberately branches on audit outcome because the spec requires enumeration before changing reviewed lines.
- Type consistency: names match existing files except newly introduced test seams (`parkConnect`, `connectStartedCount`, `releaseParkedConnects`) defined in Task 1.
