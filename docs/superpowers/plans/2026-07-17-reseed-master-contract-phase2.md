# Reseed/Master Contract (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make reseed and session finalization produce one atomic, truthful current-stack outcome, including honest no-master cases and a structurally validated fault oracle.

**Architecture:** `StackEngine` owns a stored event-driven `CurrentStackState` and returns one lock-consistent `FinalizationState`. `SessionPipeline` serializes reseed against finalization, uses that snapshot exactly once after draining, and commits the resulting facts with `end_time` in one manifest transaction. `SessionManifest` stores optional final-only facts for backward compatibility, while the fault oracle validates the new outcome exhaustively and preserves the prior legacy rule.

**Tech Stack:** Swift 5.10 package, Foundation locking, XCTest, existing FITS reader/writer and FaultKit oracle.

## Global Constraints

- Follow strict red-green-refactor: no production change before a discriminating failing test.
- Do not change watcher reducer behavior in Phase 2.
- Session accepted/rejected counts are monotone; reseed never resets them.
- Current-stack accumulator, reference, count, and derived exposure reset on manual and automatic reseed.
- `CurrentStackState` is stored and event-driven; never derive it from accumulator/count history.
- `end()` uses exactly one `StackEngine.finalizationState()` snapshot after the drain.
- Claim the finalization barrier only after reentrant and session-state guards; keep it claimed after failed finalization.
- `masterExpected` remains immutable and session-semantic.
- Persist counts, not current-stack exposure; derive `TOTALEXP = stackFrameCount * subExposureSeconds`.
- New manifest fields are optional so legacy manifests decode unchanged.
- A failed master write or invariant breach must leave `end_time == nil`.
- Finite-import reseed is explicitly rejected and logged; no silent no-op.
- Phase 3 P2 fixes, Siril parity, versioning, and tagging are out of scope.

---

### Task 1: Store current-stack state and expose one atomic finalization snapshot

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Test: `Tests/LiveAstroCoreTests/StackEngineFinalizationStateTests.swift`
- Test: `Tests/LiveAstroCoreTests/AutoReseedTests.swift`

**Interfaces:**
- Produces `StackEngine.CurrentStackState: Equatable` with `.initialEmpty`, `.active`, and `.awaitingSeedAfterReseed(manual:auto:)`.
- Produces `StackEngine.FinalizationState` containing `image`, `coverage`, `frameCount`, `stackState`, `sessionAcceptedCount`, and `sessionRejectedCount` from one lock acquisition.
- Produces `StackEngine.finalizationState() throws -> FinalizationState` and `StackEngine.FinalizationError.invariantBreach`.
- Keeps `currentStack()`, `currentCoverage()`, `stackFrameCount`, `acceptedCount`, `rejectedCount`, and `autoReseedCount` source-compatible.

- [ ] **Step 1: Add red tests for named state transitions**

Create `StackEngineFinalizationStateTests.swift` with a deterministic accepted seed fixture already used by `StackEngineTests`, then pin:

```swift
func testStoredStateTransitionsInitialSeedManualReseedAndReseedAgain() throws {
    let engine = StackEngine(seedMinStars: 1)
    XCTAssertEqual(try engine.finalizationState().stackState, .initialEmpty)
    XCTAssertEqual(engine.process(starFrame(name: "seed")), .becameReference)
    XCTAssertEqual(try engine.finalizationState().stackState, .active)
    engine.reseed()
    XCTAssertEqual(try engine.finalizationState().stackState,
                   .awaitingSeedAfterReseed(manual: 1, auto: 0))
    XCTAssertEqual(engine.process(starFrame(name: "new-seed")), .becameReference)
    XCTAssertEqual(try engine.finalizationState().stackState, .active)
    engine.reseed()
    XCTAssertEqual(try engine.finalizationState().stackState,
                   .awaitingSeedAfterReseed(manual: 2, auto: 0))
}
```

Extend `AutoReseedTests` to assert the stored state becomes `.awaitingSeedAfterReseed(manual: 0, auto: 1)` at the existing six-failure boundary and returns to `.active` on the next accepted seed.

- [ ] **Step 2: Verify the state tests fail for the missing API**

Run:

```bash
swift test --filter 'StackEngineFinalizationStateTests|AutoReseedTests'
```

Expected: compilation fails because `CurrentStackState` / `finalizationState()` do not exist.

- [ ] **Step 3: Implement stored state transitions only**

Add under `StackEngine`:

```swift
public enum CurrentStackState: Equatable {
    case initialEmpty
    case active
    case awaitingSeedAfterReseed(manual: Int, auto: Int)
}

private var currentStackState: CurrentStackState = .initialEmpty
private var manualReseedCount = 0
```

Transition to `.active` at both seed sites (`processLocked` and `seedReference`); manual `reseed()` increments `manualReseedCount` and stores `.awaitingSeedAfterReseed(manual:auto:)`; auto-reseed increments the existing counter and stores the same case with both totals. Do not infer state from `accumulator`.

- [ ] **Step 4: Add red tests for atomic facts and invariant refusal**

Pin that a post-reseed stack reports current count/image/coverage while retaining session totals:

```swift
func testFinalizationStateSeparatesCurrentStackFromSessionHistory() throws {
    let engine = StackEngine(seedMinStars: 1)
    _ = engine.process(starFrame(name: "old-seed"))
    engine.reseed()
    _ = engine.process(starFrame(name: "new-seed"))
    let final = try engine.finalizationState()
    XCTAssertEqual(final.stackState, .active)
    XCTAssertEqual(final.frameCount, 1)
    XCTAssertEqual(final.sessionAcceptedCount, 2)
    XCTAssertEqual(final.sessionRejectedCount, 0)
    XCTAssertNotNil(final.image)
    XCTAssertNotNil(final.coverage)
}
```

Add an internal test-only mutation helper guarded by `@testable` visibility:

```swift
func forceAccumulatorLossForTesting() {
    lock.withLock { accumulator = nil }
}
```

Then assert `.active` plus a missing accumulator throws `.invariantBreach`, and `.initialEmpty` plus nonzero accepted history also throws. The helper must alter only the accumulator so the stored-vs-reality disagreement remains observable.

- [ ] **Step 5: Verify the snapshot tests fail for the missing behavior**

Run the same filter. Expected: new assertions fail because no atomic finalization snapshot or invariant validation exists.

- [ ] **Step 6: Implement `FinalizationState` and validation under one lock**

Implement:

```swift
public enum FinalizationError: Error, Equatable { case invariantBreach }

public struct FinalizationState {
    public let image: AstroImage?
    public let coverage: [Float]?
    public let frameCount: Int
    public let stackState: CurrentStackState
    public let sessionAcceptedCount: Int
    public let sessionRejectedCount: Int
}

public func finalizationState() throws -> FinalizationState {
    try lock.withLock {
        let frameCount = accumulator?.frameCount ?? 0
        switch currentStackState {
        case .initialEmpty:
            guard accumulator == nil, acceptedCount == 0 else { throw FinalizationError.invariantBreach }
        case .active:
            guard accumulator != nil, frameCount > 0 else { throw FinalizationError.invariantBreach }
        case .awaitingSeedAfterReseed:
            guard accumulator == nil, frameCount == 0 else { throw FinalizationError.invariantBreach }
        }
        return FinalizationState(image: accumulator?.mean(), coverage: accumulator?.coverage(),
                                 frameCount: frameCount, stackState: currentStackState,
                                 sessionAcceptedCount: acceptedCount,
                                 sessionRejectedCount: rejectedCount)
    }
}
```

Keep existing snapshot accessors, but `SessionPipeline.end()` must stop using them in Task 3.

- [ ] **Step 7: Run focused and sibling tests**

Run:

```bash
swift test --filter 'StackEngineFinalizationStateTests|StackEngineTests|StackEngineStagedTests|AutoReseedTests|RejectionEngineTests|BatchImporterTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/StackEngineFinalizationStateTests.swift Tests/LiveAstroCoreTests/AutoReseedTests.swift
git commit -m "feat: add atomic stack finalization state"
```

---

### Task 2: Add backward-compatible manifest finalization facts

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionModels.swift`
- Modify: `Sources/LiveAstroCore/Session/SessionManager.swift`
- Test: `Tests/LiveAstroCoreTests/SessionManagerTests.swift`
- Test: `Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift`

**Interfaces:**
- Produces `MasterOutcome: String, Codable, Equatable` with `.written`, `.awaitingSeed`, `.noFrames`.
- Produces `SessionFinalizationFacts` with `masterOutcome`, `stackFrameCount`, `sessionAcceptedCount`, and `sessionRejectedCount`.
- Extends `SessionManifest` with optional `masterOutcome`, `stackFrameCount`, `sessionAcceptedCount`, and `sessionRejectedCount`.
- Extends `SessionManager.endSession(at:finalization:)`; `finalization` defaults to `nil` so watcher/bare-manager call sites remain source-compatible.

- [ ] **Step 1: Add red schema round-trip and legacy-decode tests**

In `SessionManagerTests`, construct a native session, end it with:

```swift
SessionFinalizationFacts(masterOutcome: .written, stackFrameCount: 3,
                         sessionAcceptedCount: 7, sessionRejectedCount: 2)
```

Decode the persisted manifest and assert all four facts plus `endTime`. Add a JSON fixture containing `master_expected` but none of the four new fields and assert all new properties decode as `nil`.

- [ ] **Step 2: Verify schema tests fail**

Run `swift test --filter SessionManagerTests`. Expected: compilation fails because the new types and fields do not exist.

- [ ] **Step 3: Implement optional schema and transactional end commit**

Add:

```swift
public enum MasterOutcome: String, Codable, Equatable {
    case written
    case awaitingSeed = "awaiting_seed"
    case noFrames = "no_frames"
}

public struct SessionFinalizationFacts: Equatable {
    public let masterOutcome: MasterOutcome
    public let stackFrameCount: Int
    public let sessionAcceptedCount: Int
    public let sessionRejectedCount: Int
}
```

Add optional manifest fields with `nil` defaults. Change `endSession` to copy facts into the proposed manifest before its one `persist` call and before mutating in-memory state:

```swift
public func endSession(at date: Date = .init(),
                       finalization: SessionFinalizationFacts? = nil) throws {
    // existing guards
    proposed.endTime = date
    proposed.masterOutcome = finalization?.masterOutcome
    proposed.stackFrameCount = finalization?.stackFrameCount
    proposed.sessionAcceptedCount = finalization?.sessionAcceptedCount
    proposed.sessionRejectedCount = finalization?.sessionRejectedCount
    try persist(proposed, to: dir)
    manifest = proposed
    state = .ended
}
```

- [ ] **Step 4: Add a write-failure atomicity regression**

Use `manifestWriter` to throw during `endSession(finalization:)`; assert `state == .running`, `manifest.endTime == nil`, and all new in-memory final fields remain `nil`.

- [ ] **Step 5: Verify red, then retain the write-before-commit implementation**

Run `swift test --filter SessionManagerTests` before and after the minimal implementation. Expected final result: all selected tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/LiveAstroCore/Session/SessionModels.swift Sources/LiveAstroCore/Session/SessionManager.swift Tests/LiveAstroCoreTests/SessionManagerTests.swift Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift
git commit -m "feat: persist session finalization facts"
```

---

### Task 3: Serialize reseed with finalization and write masters from the atomic snapshot

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineReseedContractTests.swift`
- Test: `Tests/LiveAstroCoreTests/NativePipelineTests.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineShutdownTests.swift`

**Interfaces:**
- Produces `SessionPipeline.ReseedResult: Equatable` with `.reseeded`, `.notNative`, `.unavailableDuringImport`, `.finalizationInProgress`.
- Changes `SessionPipeline.reseed()` to `@discardableResult public func reseed() -> ReseedResult`.
- Consumes Task 1 `StackEngine.finalizationState()` exactly once per `end()` after drain.
- Consumes Task 2 `SessionFinalizationFacts` in the same `endSession` commit that stamps `end_time`.

- [ ] **Step 1: Add red tests for typed finite-import refusal and app-visible result**

Create `SessionPipelineReseedContractTests` with finite and live `FrameSource` fakes. Before `start()` and while a finite native import is running, assert `pipeline.reseed() == .unavailableDuringImport` and the engine remains unchanged. For live native mode assert `.reseeded`; watcher mode asserts `.notNative`.

- [ ] **Step 2: Verify the reseed-result tests fail**

Run `swift test --filter SessionPipelineReseedContractTests`. Expected: compilation fails because `reseed()` returns `Void` and has no typed refusal.

- [ ] **Step 3: Implement the pipeline barrier and typed reseed result**

Add a dedicated lock and sticky flag:

```swift
private let finalizationLock = NSLock()
private var finalizationClaimed = false

public enum ReseedResult: Equatable {
    case reseeded, notNative, unavailableDuringImport, finalizationInProgress
}
```

Implement reseed so the finite check is explicit and the engine mutation occurs inside the same lock section that checks the barrier:

```swift
@discardableResult
public func reseed() -> ReseedResult {
    guard let engine else { return .notNative }
    guard source?.isFinite != true else { return .unavailableDuringImport }
    return finalizationLock.withLock {
        guard !finalizationClaimed else { return .finalizationInProgress }
        engine.reseed()
        return .reseeded
    }
}
```

In `end()`, retain the existing guard order and then claim the sticky barrier:

```swift
guard !isInsideCallbackDelivery else { throw SessionPipelineError.reentrantEnd }
guard session.state == .running else { throw SessionError.notRunning }
finalizationLock.withLock { finalizationClaimed = true }
```

Never clear it on `shutdownTimeout`, master-write failure, or invariant breach.

- [ ] **Step 4: Add red barrier-ordering tests**

Pin three cases:

1. A reentrant callback `end()` throws `.reentrantEnd`, then a normal live `reseed()` still returns `.reseeded` (rejected call did not claim barrier).
2. `end()` on a never-started pipeline throws `SessionError.notRunning`, then reseed still returns `.reseeded`.
3. A wedged `end()` reaches `.shutdownTimeout`; subsequent reseed returns `.finalizationInProgress`, including before a retry.

Use the bounded fakes in `SessionPipelineShutdownTests`; do not add sleeps beyond the existing synchronization points.

- [ ] **Step 5: Verify red, implement only the guard-order behavior, then verify green**

Run:

```bash
swift test --filter 'SessionPipelineReseedContractTests|SessionPipelineShutdownTests'
```

Expected final result: all selected tests pass.

- [ ] **Step 6: Update `AppModel` logging from the typed result**

Replace the unconditional “reference reseeded” line with an exhaustive switch. Required messages:

```swift
switch pipeline?.reseed() {
case .reseeded?: log.append("reference reseeded")
case .unavailableDuringImport?: log.append("reseed unavailable while an import is running")
case .finalizationInProgress?: log.append("reseed refused — session finalization has begun")
case .notNative?, nil: log.append("reseed unavailable — no native stack is active")
}
```

- [ ] **Step 7: Add red end-to-end tests for all master outcomes**

Extend `NativePipelineTests` / the new contract suite with deterministic sources:

- no reseed: preserve the existing master pixels and assert `masterOutcome == .written`;
- accept frames, manual reseed, accept K new frames, end: decode `master.fit`, assert `STACKCNT == K`, `TOTALEXP == K * subExposureSeconds`, manifest `stackFrameCount == K`, and session accepted/rejected finals retain the whole session;
- accept frames, reseed, never reseed, end: no `master.fit`, outcome `.awaitingSeed`, count `0`, and log mentions manual or automatic reseed without claiming operator-only causation;
- zero frames: no master, outcome `.noFrames`, count `0`, exact no-frames log;
- force stored `.active` / accumulator disagreement: `end()` throws `StackEngine.FinalizationError.invariantBreach`, manifest `endTime` remains nil;
- auto-reseed then end before a new seed: outcome `.awaitingSeed` and log wording covers automatic reseed.

- [ ] **Step 8: Verify the outcome tests fail against the old multi-read finalization**

Run:

```bash
swift test --filter 'NativePipelineTests|SessionPipelineReseedContractTests'
```

Expected: failures show missing outcome fields, old session-total `STACKCNT`, false zero-frame wording after reseed, and breach not refused.

- [ ] **Step 9: Replace the end-time engine reads with one snapshot**

After the drain and directory guard, call `let final = try eng.finalizationState()` once. Switch on `final.stackState`:

```swift
case .active:
    guard let image = final.image else { throw StackEngine.FinalizationError.invariantBreach }
    // crop/balance/write using final.coverage
    // FITS stackCount = final.frameCount
    // TOTALEXP = Double(final.frameCount) * profile.subExposureSeconds
    outcome = .written
case .awaitingSeedAfterReseed:
    onLog?("reference cleared by reseed (manual or automatic) and never re-seeded — no master available (\(session.acceptedCount) snapshots retained)")
    outcome = .awaitingSeed
case .initialEmpty:
    onLog?("no frames accepted — no master written")
    outcome = .noFrames
```

Create `SessionFinalizationFacts` from that same snapshot and pass it to `session.endSession(finalization:)`. Do not call `currentStack()`, `currentCoverage()`, `stackFrameCount`, `acceptedCount`, or `rejectedCount` anywhere in `end()` after this change. Watcher mode keeps its existing log and calls `endSession()` without native facts.

- [ ] **Step 10: Run focused pipeline, shutdown, FITS, and manifest tests**

Run:

```bash
swift test --filter 'NativePipelineTests|SessionPipelineReseedContractTests|SessionPipelineShutdownTests|SessionManagerTests|FITSWriterMetadataTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 11: Commit Task 3**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Sources/LiveAstroStudio/AppModel.swift Tests/LiveAstroCoreTests/SessionPipelineReseedContractTests.swift Tests/LiveAstroCoreTests/NativePipelineTests.swift Tests/LiveAstroCoreTests/SessionPipelineShutdownTests.swift
git commit -m "feat: enforce truthful reseed master finalization"
```

---

### Task 4: Make oracle clause 5 validate the typed outcome and actual FITS master

**Files:**
- Modify: `Tests/LiveAstroCoreTests/FaultKit/OracleAssert.swift`
- Modify: `Tests/LiveAstroCoreTests/FaultKitTests.swift`
- Modify: `Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift`

**Interfaces:**
- Consumes `SessionManifest.masterOutcome` and `stackFrameCount` from Tasks 2–3.
- Uses production `FITSReader.readHeader` plus `FITSReader.read` to validate header facts and pixel payload structure.
- Preserves legacy behavior: ended `masterExpected == true` manifests lacking new outcome fields require a master when `snapshots` is nonempty; manifests lacking `masterExpected` remain era-exempt.

- [ ] **Step 1: Add red oracle-teeth tests**

Use `XCTExpectFailure` fixtures to prove clause 5 rejects:

- `.written` with missing `master.fit`;
- `.written` with nonempty garbage `master.fit`;
- `.written` with decoded `STACKCNT` different from manifest `stackFrameCount`;
- `.awaitingSeed` with a missing honest reseed log;
- `.noFrames` with a missing no-frames log;
- an ended native manifest with no `masterOutcome` but snapshots and no master (legacy fallback).

Also add passing fixtures for all three outcomes and for ancient `masterExpected == nil` decoding.

- [ ] **Step 2: Verify the new teeth tests expose the old weak oracle**

Run:

```bash
swift test --filter 'FaultKitTests|FaultMatrixLifecycleTests'
```

Expected: the new expected-failure blocks report that the weak oracle did not fail for corruption/mismatch/log cases.

- [ ] **Step 3: Implement exhaustive clause 5**

For ended native manifests:

```swift
switch manifest.masterOutcome {
case .written?:
    // require stackFrameCount, regular/nonempty master,
    // FITSReader.readHeader + FITSReader.read decode,
    // parse Int(header.keywords["STACKCNT"]), compare exact count
case .awaitingSeed?:
    // require stackFrameCount == 0 and a reseed/never-re-seeded log match
case .noFrames?:
    // require stackFrameCount == 0 and exact no-frames log match
case nil:
    // legacy fallback: if snapshots nonempty, require the master as review-11 did
}
```

Factor a local `assertDecodableMaster` helper only if it keeps one failure message per clause. Do not accept existence or nonempty bytes as structural validity.

- [ ] **Step 4: Update lifecycle fixtures to record typed facts**

Where tests manufacture post-schema ended native manifests, populate the appropriate `masterOutcome`, `stackFrameCount`, and session finals. Leave explicitly legacy fixtures without them so fallback coverage remains real.

- [ ] **Step 5: Run the fault pillar and contract suites**

Run:

```bash
swift test --filter 'FaultKitTests|FaultMatrixLifecycleTests|NativePipelineTests|SessionPipelineReseedContractTests'
```

Expected: all selected tests pass, including the intentional oracle-teeth expectations.

- [ ] **Step 6: Commit Task 4**

```bash
git add Tests/LiveAstroCoreTests/FaultKit/OracleAssert.swift Tests/LiveAstroCoreTests/FaultKitTests.swift Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift
git commit -m "test: strengthen master outcome oracle"
```

---

### Task 5: Phase 2 verification and review handoff

**Files:**
- Modify only if verification exposes a Phase 2 defect.

**Interfaces:**
- Produces a reviewed Phase 2 branch ready for merge; does not start Phase 3.

- [ ] **Step 1: Run ownership and contract searches**

Run:

```bash
rg -n 'currentStack\(\)|currentCoverage\(\)|stackFrameCount|acceptedCount|rejectedCount' Sources/LiveAstroCore/Pipeline/SessionPipeline.swift
rg -n 'masterOutcome|stackFrameCount|sessionAcceptedCount|sessionRejectedCount' Sources Tests
git diff --check
```

Expected: `end()` has no split engine reads; new facts have one schema spelling; diff check is clean.

- [ ] **Step 2: Run the focused Phase 2 gate**

```bash
swift test --filter 'StackEngineFinalizationStateTests|AutoReseedTests|BatchImporterTests|SessionManagerTests|SessionPipelineReseedContractTests|NativePipelineTests|SessionPipelineShutdownTests|FaultKitTests|FaultMatrixLifecycleTests'
```

Expected: zero failures.

- [ ] **Step 3: Run the full suite exactly once**

```bash
swift test
```

Expected: zero failures; record test/skip counts and inherited warnings separately.

- [ ] **Step 4: Run release and test-build warning gates**

```bash
swift build -c release
swift test --filter StackEngineFinalizationStateTests -Xswiftc -DPHASE2_WARNING_AUDIT
```

Expected: release clean; no new Phase 2 production/test warnings. Do not claim repository-wide zero warnings if inherited warnings remain—Phase 3 owns the named test-warning cleanup.

- [ ] **Step 5: Request correctness and maintainability reviews**

Give reviewers only the approved spec, base/head range, and the invariant; require them to inspect atomicity, barrier ordering, manifest compatibility, log honesty, oracle teeth, and finite-import enforcement. Fix every confirmed finding red-first and rerun the affected gates.

- [ ] **Step 6: Commit any review fixes and record evidence**

```bash
git status --short
git log --oneline main..HEAD
git diff --check main...HEAD
```

Expected: clean tree, intentional Phase 2 commits only. Update `.superpowers/sdd/progress.md` with exact commits, tests, warnings, and review verdicts. Stop for merge authorization; Phase 3 remains parked.

## Execution handoff

Execute inline in this session under `superpowers:executing-plans`, using strict TDD and a review checkpoint after each task. The user has already authorized continuing the approved three-phase sequence; no additional design choice is required. Do not merge or push until Phase 2 has passed its complete verification and review gate.
