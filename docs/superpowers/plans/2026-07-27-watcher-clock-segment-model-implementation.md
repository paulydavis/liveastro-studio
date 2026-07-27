# Watcher Clock Segment Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the watcher's scalar victim-blocking clock with per-owner accrual segments so numbered-revision holdback is bounded, attributable, and driver-faithful across emitted, vanished, absent, and padding-variant blockers.

**Architecture:** Keep the existing watcher reducer and driver protocol. The change is a narrow state-model swap inside `WatcherFileState.swift`: `VictimBlockingClock` becomes `VictimWaitLedger`, owner identity becomes normalized numeric `RevisionKey`, and write-off decisions consume structured per-owner debt after yielded settlements, tombstone pauses, discharge scans, and convergence grace are applied. Tests lead the change by reconciling the scalar-era batteries, then pinning each transition against real reducer and driver composition.

**Tech Stack:** SwiftPM, Swift, XCTest, LiveAstroCore watcher reducer, existing `StackFileWatcher` filesystem integration tests.

## Global Constraints

- Preserve the existing watcher reducer architecture, file state machine, stat/digest gates, folder-generation rules, identity/digest verification, numeric ordering comparator, and tombstone synthesis.
- Do not change FITS completeness, digest policy, immutable vs. mutable stacker-output behavior, relay logic, OBS, SessionPipeline, app UI, packaging, notarization, or release artifacts.
- Segment owners are normalized numeric revisions. Raw filenames are valid for logs and emission intents only.
- `RevisionKey` ordering must delegate to the existing digit-string numeric comparator; lexicographic ordering makes `"10"` sort before `"9"` and is a correctness bug.
- Redemption fires only from `.emissionFinished` for the current generation when the outcome is `.yielded` and the candidate settles as `.emittedNow`.
- Observe-time emission intents never redeem debt. Pending intents install a narrow barrier that prevents successor-owner segment charging, consumption, or write-off until the intents settle or become non-yielded.
- Vanished owners do not redeem. Their debt carries only while the victim remains continuously blocked or absent.
- Debt discharges after the victim's own yielded emission and after one full observe pass where the victim is present and unblocked.
- For discharge, unblocked means a file-state and numeric-order fact: the victim is present and no unready lower revision exists in the current generation. Do not derive unblocked from `BlockingEpisode`, segment charging, or the pending-emission barrier.
- Write-off requires enough unredeemed victim wait and expiration of the current owner's own convergence grace window.
- Write-off logs must separate the current blocker's own attributed time from consumed predecessor debt.
- One blocked higher revision is enough to write off the head blocker; do not silently change to an all-victims threshold.
- Run driver-faithful composition tests before claiming convergence. Reducer-only injected states are development probes, not final acceptance evidence.

---

## File Structure

- Modify `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
  - Replace `ChargingBlocker` and `VictimBlockingClock` with `RevisionKey`, `AccrualSegment`, `VictimWaitLedger`, and `WriteOffDecision`.
  - Replace `RevisionOrderingState.victimClocks` with `RevisionOrderingState.victimLedgers`.
  - Update `BlockingEpisode` to identify the current head blocker by raw filename plus normalized owner key, without storing scalar deadlines.
  - Keep the existing reducer command protocol and emission intent flow.
  - Keep `NumberedRevisionOrder` as the single numeric-order implementation.
- Modify `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
  - Rename helper arguments from `victimClocks` to `victimLedgers`.
  - Add focused red-first tests for ledger primitives, yielded redemption, pending-emission barrier, absent tombstones, discharge, convergence grace, write-off attribution, and scalar-era counterexamples.
  - Update state equality helpers to compare `victimLedgers`.
- Modify `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`
  - Replace scalar timing invariants with segment-model timing invariants, including first-charge-plus-budget and explicit predecessor-debt exceptions.
- Create `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`
  - Record each scalar-era battery expectation that changes under the approved segment model and the exact spec clause that justifies the new expectation.

---

### Task 1: Reconcile Battery Expectations Before Changing Production State

**Files:**
- Create: `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`

**Interfaces:**
- Consumes: approved spec in `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md`.
- Produces: reconciled test names and expected outcomes that later tasks must satisfy.

- [ ] **Step 1: Write the reconciliation document**

Add this file exactly, then expand it only with concrete test names discovered while editing:

```markdown
# Watcher Clock Battery Reconciliation

**Spec:** `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md`

The scalar-era batteries remain binding only after their expectations are re-derived from the segment model. This document records the expected changes so the implementation cannot silently swap a failing probe for an easier one.

## Reconciled expectations

| Probe family | Old scalar-era expectation | Segment-model expectation | Spec clause |
|---|---|---|---|
| d9 emitted-owner pause | Round 7 writes off the successor at about 9s; the segment model must redeem owner debt on yielded emission and give the successor its own budget. | Red on round 7 control, green on segment model at about one fresh budget. | §§4, 5.1 |
| d4 vanished-owner carry | A vanished owner does not redeem. A successor may consume unresolved predecessor debt once its own convergence grace expires. | Green only when the log separates successor time from consumed predecessor debt. | §§5.2, 5.4, 5.5 |
| b1 / W4-2a unblocked discharge | A victim present and unblocked for a full observe pass clears stale debt before a later fresh blocker appears. | Later fresh blocker receives a fresh budget. | §5.2 |
| e1 / e7 unrelated lower emission | Emission of an unrelated lower owner must not clear debt charged to a still-live owner. | No unbounded hold; write-off occurs after unredeemed wait plus current-owner grace. | §§5.1, 5.4 |
| h3 / h4 same-batch handoff | Observe-time intent does not redeem; successor charging waits for yielded settlement. | Red on all scalar controls, green on segment model with the pending-emission barrier. | §4 |
| padding rename during absence | Raw filename padding changes do not create a new owner. | `live_stack_7.fit` and `live_stack_007.fit` redeem and consume the same `RevisionKey`. | §3.1 |
| e9 bounded non-growing wait | A chain of resolving blockers can exceed one budget in total wall time. | Starvation is bounded over unredeemed wait only. | §5.3 |
```

- [ ] **Step 2: Verify the reconciliation names every required probe**

Run: `rg -n "d9|d4|b1|W4-2a|e1|e7|h3|h4|padding|e9" docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`

Expected: output contains all ten probe labels from the reconciliation table.

- [ ] **Step 3: Commit the reconciliation**

```bash
git add docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md
git commit -m "test: reconcile watcher clock segment batteries"
```

---

### Task 2: Add RevisionKey and VictimWaitLedger Primitives

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: existing `NumberedRevisionOrder.revision(in:)`, `NumberedRevisionOrder.compare(_:_:)`, and `NumberedRevisionOrder.orderedBefore(_: _:)`.
- Produces:
  - `struct RevisionKey: Hashable, Equatable`
  - `struct AccrualSegment: Equatable`
  - `struct VictimWaitLedger: Equatable`
  - `struct WriteOffDecision: Equatable`
  - `NumberedRevisionOrder.revisionKey(in:) -> RevisionKey?`
  - `NumberedRevisionOrder.orderedBefore(_ lhs: RevisionKey, _ rhs: RevisionKey) -> Bool`
  - `NumberedRevisionOrder` changed from `private struct` to internal `struct` so tests can exercise numeric owner ordering directly.

- [ ] **Step 1: Write failing primitive tests**

Add these tests to `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`:

```swift
func testRevisionKeyNormalizesPaddingAndUsesNumericOrdering() {
    let order = NumberedRevisionOrder(prefix: "live_stack")

    XCTAssertEqual(
        order.revisionKey(in: "live_stack_7.fit"),
        order.revisionKey(in: "live_stack_007.fit"))
    XCTAssertTrue(order.orderedBefore(RevisionKey("9"), RevisionKey("10")))
    XCTAssertFalse(order.orderedBefore(RevisionKey("10"), RevisionKey("9")))
}

func testVictimWaitLedgerAccruesPausesRedeemsAndTotalsSegments() {
    var ledger = VictimWaitLedger()
    let first = RevisionKey("1")
    let second = RevisionKey("2")

    ledger.startOrContinue(owner: first, at: 10)
    ledger.pause(at: 30)
    XCTAssertEqual(ledger.totalUnredeemedNanos(at: 100), 20)

    ledger.startOrContinue(owner: second, at: 100)
    XCTAssertEqual(ledger.totalUnredeemedNanos(at: 120), 40)

    ledger.redeem(owner: first)
    XCTAssertEqual(ledger.totalUnredeemedNanos(at: 120), 20)
    XCTAssertEqual(ledger.segments.keys.sorted(by: { $0.normalizedDigits < $1.normalizedDigits }), [second])
}
```

- [ ] **Step 2: Run tests to verify the types are missing**

Run: `swift test --filter WatcherReducerTests/testRevisionKeyNormalizesPaddingAndUsesNumericOrdering`

Expected: FAIL with errors naming missing `RevisionKey`, `VictimWaitLedger`, or new `NumberedRevisionOrder` methods.

- [ ] **Step 3: Add primitive types and numeric helpers**

Replace the old clock structs near the top of `Sources/LiveAstroCore/Watch/WatcherFileState.swift` with:

```swift
struct RevisionKey: Hashable, Equatable, ExpressibleByStringLiteral {
    let normalizedDigits: String

    init(_ digits: String) {
        let stripped = digits.drop { $0 == "0" }
        normalizedDigits = stripped.isEmpty ? "0" : String(stripped)
    }

    init(stringLiteral value: String) {
        self.init(value)
    }
}

struct AccrualSegment: Equatable {
    let owner: RevisionKey
    var firstChargeNanos: UInt64
    var accruedNanos: UInt64
    var runningSinceNanos: UInt64?

    var isRunning: Bool {
        runningSinceNanos != nil
    }

    func totalNanos(at nowNanos: UInt64) -> UInt64 {
        guard let runningSinceNanos else { return accruedNanos }
        return accruedNanos &+ (nowNanos >= runningSinceNanos ? nowNanos - runningSinceNanos : 0)
    }
}

struct VictimWaitLedger: Equatable {
    var segments: [RevisionKey: AccrualSegment] = [:]
    var pausedAtNanos: UInt64?

    var isEmpty: Bool {
        segments.isEmpty
    }

    mutating func startOrContinue(owner: RevisionKey, at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        pausedAtNanos = nil
        if var segment = segments[owner] {
            if segment.runningSinceNanos == nil {
                segment.runningSinceNanos = nowNanos
            }
            segments[owner] = segment
        } else {
            segments[owner] = AccrualSegment(
                owner: owner,
                firstChargeNanos: nowNanos,
                accruedNanos: 0,
                runningSinceNanos: nowNanos)
        }
    }

    mutating func pause(at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        if pausedAtNanos == nil {
            pausedAtNanos = nowNanos
        }
    }

    mutating func pauseRunning(at nowNanos: UInt64) {
        for key in segments.keys {
            guard var segment = segments[key],
                  let runningSinceNanos = segment.runningSinceNanos else { continue }
            segment.accruedNanos = segment.accruedNanos &+ (nowNanos >= runningSinceNanos ? nowNanos - runningSinceNanos : 0)
            segment.runningSinceNanos = nil
            segments[key] = segment
        }
    }

    mutating func redeem(owner: RevisionKey) {
        segments.removeValue(forKey: owner)
        if segments.isEmpty {
            pausedAtNanos = nil
        }
    }

    mutating func discharge(at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        segments.removeAll()
        pausedAtNanos = nil
    }

    mutating func consume(_ consumed: [RevisionKey: UInt64], at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        for owner in consumed.keys {
            segments.removeValue(forKey: owner)
        }
        if segments.isEmpty {
            pausedAtNanos = nil
        }
    }

    func totalUnredeemedNanos(at nowNanos: UInt64) -> UInt64 {
        segments.values.reduce(0) { partial, segment in
            partial &+ segment.totalNanos(at: nowNanos)
        }
    }
}

struct WriteOffDecision: Equatable {
    let blocker: RevisionKey
    let blockerNameForLog: String
    let attributedNanos: UInt64
    let consumedSegments: [RevisionKey: UInt64]
}
```

Change the `NumberedRevisionOrder` declaration line from:

```swift
private struct NumberedRevisionOrder {
```

to:

```swift
struct NumberedRevisionOrder {
```

Then extend `NumberedRevisionOrder`:

```swift
func revisionKey(in name: String) -> RevisionKey? {
    revision(in: name).map(RevisionKey.init)
}

func orderedBefore(_ lhs: RevisionKey, _ rhs: RevisionKey) -> Bool {
    compare(lhs.normalizedDigits, rhs.normalizedDigits) == .orderedAscending
}
```

- [ ] **Step 4: Run primitive tests**

Run: `swift test --filter WatcherReducerTests/testRevisionKeyNormalizesPaddingAndUsesNumericOrdering`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testVictimWaitLedgerAccruesPausesRedeemsAndTotalsSegments`

Expected: PASS.

- [ ] **Step 5: Commit primitives**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "feat: add watcher victim wait ledgers"
```

---

### Task 3: Replace Scalar Clock Storage With Ledger Storage

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.startOrContinue(owner:at:)`, `VictimWaitLedger.pause(at:)`, `VictimWaitLedger.discharge(at:)`.
- Produces:
  - `RevisionOrderingState.victimLedgers: [String: VictimWaitLedger]`
  - `BlockingEpisode(blocker:owner:victims:)`
  - compile-clean reducer using ledgers instead of `VictimBlockingClock`

- [ ] **Step 1: Write failing generation-hygiene tests**

Replace old scalar assertions with:

```swift
func testGenerationChangeClearsVictimLedgersButKeepsDigestDedup() {
    let victim = revisionName("00002")
    var reducer = makeReducer(
        files: [
            revisionName("00001"): .writtenOff,
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(2),
                digest: "victim",
                kind: .numbered(revision: "00002")))
        ],
        digests: [victim: "victim"],
        victimLedgers: [
            victim: VictimWaitLedger(
                segments: [
                    RevisionKey("1"): AccrualSegment(
                        owner: RevisionKey("1"),
                        firstChargeNanos: 10,
                        accruedNanos: 20,
                        runningSinceNanos: nil)
                ],
                pausedAtNanos: 30)
        ])

    let effects = reducer.reduce(.folderGenerationChanged(FolderGeneration(rawValue: 2)))

    XCTAssertTrue(effects.isEmpty)
    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
    XCTAssertEqual(reducer.state.lastEmittedDigestByName[victim], "victim")
}
```

- [ ] **Step 2: Run the new test to verify the old storage fails**

Run: `swift test --filter WatcherReducerTests/testGenerationChangeClearsVictimLedgersButKeepsDigestDedup`

Expected: FAIL with missing `victimLedgers` or old `victimClocks` references.

- [ ] **Step 3: Update storage names and helper signatures**

In `Sources/LiveAstroCore/Watch/WatcherFileState.swift`, replace:

```swift
struct RevisionOrderingState {
    var activeBlocker: BlockingEpisode?
    var victimClocks: [String: VictimBlockingClock] = [:]
}

struct BlockingEpisode: Equatable {
    let blocker: String
    let startNanos: UInt64
    var deadlineNanos: UInt64
    private(set) var victims: Set<String>
}
```

with:

```swift
struct RevisionOrderingState {
    var activeBlocker: BlockingEpisode?
    var victimLedgers: [String: VictimWaitLedger] = [:]
}

struct BlockingEpisode: Equatable {
    let blocker: String
    let owner: RevisionKey
    private(set) var victims: Set<String>

    init?(blocker: String, owner: RevisionKey, victims: Set<String>) {
        guard !victims.isEmpty else { return nil }
        self.blocker = blocker
        self.owner = owner
        self.victims = victims
    }

    mutating func refreshVictims(_ victims: Set<String>) -> Bool {
        guard !victims.isEmpty else { return false }
        self.victims = victims
        return true
    }

    mutating func removeVictim(named name: String) -> Bool {
        victims.remove(name)
        return !victims.isEmpty
    }
}
```

In `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`, change the helper signature to:

```swift
private func makeReducer(
    generation: UInt64 = 1,
    files: [String: FileState] = [:],
    digests: [String: String] = [:],
    activeBlocker: BlockingEpisode? = nil,
    victimLedgers: [String: VictimWaitLedger] = [:],
    digestPolicy: StackFileWatcher.DigestPolicy = .mutableStackerOutput,
    filePrefix: String? = "live_stack",
    quietPeriodNanos: UInt64 = 100,
    pollIntervalNanos: UInt64 = 1_000
) -> WatcherReducer {
    var ordering = RevisionOrderingState(activeBlocker: activeBlocker)
    ordering.victimLedgers = victimLedgers
    return WatcherReducer(
        state: WatcherState(
            generation: GenerationState(
                id: FolderGeneration(rawValue: generation),
                files: files,
                ordering: ordering),
            lastEmittedDigestByName: digests),
        configuration: makeConfiguration(
            digestPolicy: digestPolicy,
            filePrefix: filePrefix,
            quietPeriodNanos: quietPeriodNanos,
            pollIntervalNanos: pollIntervalNanos))
}
```

- [ ] **Step 4: Mechanically replace reducer storage**

Apply these semantic replacements inside reducer code:

```swift
state.generation.ordering.victimClocks
```

becomes:

```swift
state.generation.ordering.victimLedgers
```

Old scalar calls map this way:

```swift
clock.pause(at: nowNanos, chargedUnder: blocker)
clock.resume(at: nowNanos)
clock.charge(under: blocker)
clock.deadlineNanos <= nowNanos
```

become:

```swift
ledger.pause(at: nowNanos)
ledger.startOrContinue(owner: blockerOwner, at: nowNanos)
ledger.startOrContinue(owner: blockerOwner, at: nowNanos)
totalWaitWriteOffCandidate(victimLedger: ledger, nowNanos: nowNanos)
```

Add this temporary total-wait gate in Task 3 so the reducer compiles before Task 7 introduces structured attribution:

```swift
private func totalWaitWriteOffCandidate(
    victimLedger: VictimWaitLedger,
    nowNanos: UInt64
) -> Bool {
    victimLedger.totalUnredeemedNanos(at: nowNanos) >= blockingBudgetNanos
}
```

- [ ] **Step 5: Run focused reducer tests**

Run: `swift test --filter WatcherReducerTests`

Expected: compile succeeds, and failures are limited to behavior expectations that later tasks intentionally change. If compile fails on old `VictimBlockingClock`, `ChargingBlocker`, `startNanos`, or `deadlineNanos` references, finish the storage replacement before moving on.

- [ ] **Step 6: Commit storage migration**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "refactor: store watcher wait as ledgers"
```

---

### Task 4: Redeem Segments Only on Yielded Emission Settlement

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.redeem(owner:)`, `EmissionResult`, `Settlement.emittedNow`.
- Produces:
  - `private mutating func redeemSegments(for owner: RevisionKey)`
  - yielded-settlement-only redemption in the `.emissionFinished` reducer arm

- [ ] **Step 1: Add a d9 red test**

Add this test near the existing clock-ownership reducer tests:

```swift
func testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission() {
    let ownerName = revisionName("00001")
    let victim = revisionName("00002")
    let owner = RevisionKey("00001")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: owner, at: 0)
    ledger.pause(at: 22_000_000_000)

    var reducer = makeReducer(
        files: [
            ownerName: .ready(makeCandidate(
                name: ownerName,
                identity: makeIdentity(1),
                digest: "owner",
                kind: .numbered(revision: "00001"))),
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(2),
                digest: "victim",
                kind: .numbered(revision: "00002")))
        ],
        victimLedgers: [victim: ledger])

    let intent = EmissionIntent(
        generation: reducer.state.generation.id,
        candidate: makeCandidate(
            name: ownerName,
            identity: makeIdentity(1),
            digest: "owner",
            kind: .numbered(revision: "00001")))

    let effects = reducer.reduce(.emissionFinished(EmissionResult(
        intent: intent,
        outcome: .yielded)))

    XCTAssertTrue(effects.isEmpty)

    XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim]?.segments[owner])
}
```

- [ ] **Step 2: Add non-redemption tests**

Add:

```swift
func testSegmentModelRejectedEmissionDoesNotRedeemDebt() {
    let ownerName = revisionName("00001")
    let victim = revisionName("00002")
    let owner = RevisionKey("00001")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: owner, at: 0)
    ledger.pause(at: 10_000_000_000)

    var reducer = makeReducer(
        files: [ownerName: .ready(makeCandidate(
            name: ownerName,
            identity: makeIdentity(1),
            digest: "owner",
            kind: .numbered(revision: "00001")))],
        victimLedgers: [victim: ledger])

    let intent = EmissionIntent(
        generation: reducer.state.generation.id,
        candidate: makeCandidate(
            name: ownerName,
            identity: makeIdentity(1),
            digest: "owner",
            kind: .numbered(revision: "00001")))

    _ = reducer.reduce(.emissionFinished(EmissionResult(
        intent: intent,
        outcome: .rejected)))

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim]?.segments[owner])
}
```

- [ ] **Step 3: Run the redemption tests to verify they fail**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission`

Expected: FAIL because debt is not yet redeemed by owner-keyed yielded settlement.

Run: `swift test --filter WatcherReducerTests/testSegmentModelRejectedEmissionDoesNotRedeemDebt`

Expected: PASS. A failure showing debt redemption on `.rejected` is the regression this task fixes.

- [ ] **Step 4: Implement yielded-only uniform redemption**

In the `.emissionFinished` reducer arm, after the candidate has actually settled `.emittedNow`, add:

```swift
if case .yielded = result.outcome,
   let owner = revisionOrder.revisionKey(in: result.intent.candidate.name),
   case .settled(.emittedNow) = state.generation.files[result.intent.candidate.name] {
    redeemSegments(for: owner)
}
```

```swift
private mutating func redeemSegments(for owner: RevisionKey) {
    for victim in Array(state.generation.ordering.victimLedgers.keys) {
        state.generation.ordering.victimLedgers[victim]?.redeem(owner: owner)
        if state.generation.ordering.victimLedgers[victim]?.isEmpty == true {
            state.generation.ordering.victimLedgers[victim] = nil
        }
    }
}
```

- [ ] **Step 5: Run redemption tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelRejectedEmissionDoesNotRedeemDebt`

Expected: PASS.

- [ ] **Step 6: Commit redemption**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "fix: redeem watcher debt on yielded emission"
```

---

### Task 5: Add the Pending-Emission Barrier

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Modify: `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`

**Interfaces:**
- Consumes: yielded-only redemption from Task 4.
- Produces:
  - `RevisionOrderingState.pendingEmissionOwners: Set<RevisionKey>`
  - observe-pass deferral of successor charging, consumption, and write-off while predecessor intents are unsettled

- [ ] **Step 1: Add an h4 reducer red test**

Add this test near the other reducer clock tests:

```swift
func testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles() {
    let resolving = observation(
        name: revisionName("00001"),
        revision: "00001",
        outcome: .digested(
            identity: makeIdentity(1),
            digest: "r1",
            byteCount: makeIdentity(1).size))
    let successor = invalidRevision("00002")
    let victim = observation(
        name: revisionName("00003"),
        revision: "00003",
        outcome: .digested(
            identity: makeIdentity(3),
            digest: "r3",
            byteCount: makeIdentity(3).size))

    var reducer = makeReducer()
    let effects = observeBatch([resolving, successor, victim], nowNanos: 1_000, reducer: &reducer)

    XCTAssertEqual(emittedNames(in: effects), [revisionName("00001")])
    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
    XCTAssertEqual(reducer.state.generation.ordering.pendingEmissionOwners, [RevisionKey("00001")])
}
```

- [ ] **Step 2: Add a settlement-resumes-charging test**

Add:

```swift
func testSegmentModelSuccessorChargesAfterPendingEmissionSettles() {
    let first = revisionName("00001")
    let successor = revisionName("00002")
    let victim = revisionName("00003")
    var reducer = makeReducer()

    let effects = observeBatch([
        observation(name: first, revision: "00001", outcome: .digested(
            identity: makeIdentity(1),
            digest: "r1",
            byteCount: makeIdentity(1).size)),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3),
            digest: "r3",
            byteCount: makeIdentity(3).size))
    ], nowNanos: 1_000, reducer: &reducer)

    guard case .emit(let intent) = effects.first else {
        return XCTFail("expected first revision emission intent")
    }

    _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: .yielded)))
    _ = observeBatch([
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3),
            digest: "r3",
            byteCount: makeIdentity(3).size))
    ], nowNanos: 2_000, reducer: &reducer)

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("00002")])
    XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, successor)
}
```

- [ ] **Step 3: Run barrier tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles`

Expected: FAIL because the barrier state is absent or successor charging happens in the same observe.

- [ ] **Step 4: Implement the barrier state**

Add to `RevisionOrderingState`:

```swift
var pendingEmissionOwners: Set<RevisionKey> = []
```

When an observe pass returns an emission intent for a numbered revision before the first unready lower revision, insert its owner:

```swift
if let emittedOwner = revisionOrder.revisionKey(in: candidate.name) {
    state.generation.ordering.pendingEmissionOwners.insert(emittedOwner)
}
```

At the beginning of `.emissionFinished`, remove the owner from `pendingEmissionOwners` for all terminal outcomes in the current generation:

```swift
if result.intent.generation == state.generation.id,
   let owner = revisionOrder.revisionKey(in: result.intent.candidate.name) {
    state.generation.ordering.pendingEmissionOwners.remove(owner)
}
```

Before charging or writing off a successor in `.observe`, block the step when pending owners exist below it:

```swift
private func hasPendingLowerOwner(before owner: RevisionKey) -> Bool {
    state.generation.ordering.pendingEmissionOwners.contains { pending in
        revisionOrder.orderedBefore(pending, owner)
    }
}
```

Use:

```swift
guard !hasPendingLowerOwner(before: currentOwner) else {
    return effects
}
```

on the branch that opens, extends, consumes, or writes off current-owner segments.

- [ ] **Step 5: Run barrier tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelSuccessorChargesAfterPendingEmissionSettles`

Expected: PASS.

- [ ] **Step 6: Commit barrier**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/StackFileWatcherTests.swift
git commit -m "fix: defer watcher successor charging across pending emissions"
```

---

### Task 6: Implement Absence, Tombstone, and Unblocked-Discharge Semantics

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Modify: `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.pause(at:)`, `VictimWaitLedger.discharge(at:)`, `RevisionOrderingState.pendingEmissionOwners`.
- Produces:
  - driver-faithful tombstone synthesis over `victimLedgers.keys`
  - `private func isPresentAndUnblocked(name:in:) -> Bool`
  - discharge after one full observe pass present and unblocked

- [ ] **Step 1: Add a b1 discharge red test**

Add this test near the other reducer clock tests:

```swift
func testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass() {
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("00001"), at: 0)
    ledger.pause(at: 29_000_000_000)
    var reducer = makeReducer(victimLedgers: [victim: ledger])

    _ = observeBatch([
        observation(
            name: victim,
            revision: "00003",
            outcome: .digested(
                identity: makeIdentity(3),
                digest: "victim",
                byteCount: makeIdentity(3).size))
    ], nowNanos: 30_000_000_000, reducer: &reducer)

    XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim])
}
```

- [ ] **Step 2: Add the barrier-aware unblocked test**

Add:

```swift
func testSegmentModelBarrierDeferredSuccessorStillMeansVictimIsBlocked() {
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("00001"), at: 0)
    ledger.pause(at: 10_000_000_000)
    var ordering = RevisionOrderingState()
    ordering.victimLedgers = [victim: ledger]
    ordering.pendingEmissionOwners = [RevisionKey("00001")]
    var reducer = WatcherReducer(
        state: WatcherState(
            generation: GenerationState(
                id: FolderGeneration(rawValue: 1),
                files: [:],
                ordering: ordering),
            lastEmittedDigestByName: [:]),
        configuration: makeConfiguration())

    _ = observeBatch([
        invalidRevision("00002"),
        observation(
            name: victim,
            revision: "00003",
            outcome: .digested(
                identity: makeIdentity(3),
                digest: "victim",
                byteCount: makeIdentity(3).size))
    ], nowNanos: 11_000_000_000, reducer: &reducer)

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim])
}
```

- [ ] **Step 3: Run discharge tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass`

Expected: FAIL because stale debt still carries through unblocked presence.

- [ ] **Step 4: Implement tombstone synthesis and discharge**

When building the observe batch's name set, include both current files and ledger tombstones:

```swift
let namesForClassification = Set(batch.entries.map(\.name))
    .union(state.generation.files.keys)
    .union(state.generation.ordering.victimLedgers.keys)
```

For absent victims:

```swift
if currentObservationIsAbsent {
    state.generation.ordering.victimLedgers[name]?.pause(at: batch.nowNanos)
}
```

Add a file-state-based discharge check:

```swift
private func isPresentAndUnblocked(
    name: String,
    files: [String: FileState]
) -> Bool {
    guard let victimRevision = revisionOrder.revisionKey(in: name),
          isPresent(files[name]) else { return false }

    for (otherName, otherState) in files {
        guard otherName != name,
              let otherRevision = revisionOrder.revisionKey(in: otherName),
              revisionOrder.orderedBefore(otherRevision, victimRevision),
              isUnready(otherState) else { continue }
        return false
    }
    return true
}

private func isPresent(_ state: FileState?) -> Bool {
    guard let state else { return false }
    switch state {
    case .observing, .digestPending, .ready, .settled:
        return true
    case .droppedOutOfOrder, .writtenOff:
        return false
    }
}

private func isUnready(_ state: FileState) -> Bool {
    switch state {
    case .observing, .digestPending, .ready:
        return true
    case .settled, .droppedOutOfOrder, .writtenOff:
        return false
    }
}
```

At the end of each full observe pass, discharge victims that are present and unblocked:

```swift
for victim in Array(state.generation.ordering.victimLedgers.keys) {
    guard isPresentAndUnblocked(name: victim, files: state.generation.files) else { continue }
    state.generation.ordering.victimLedgers[victim]?.discharge(at: batch.nowNanos)
    state.generation.ordering.victimLedgers[victim] = nil
}
```

Do not treat `pendingEmissionOwners` as an unblocked signal.

- [ ] **Step 5: Run discharge tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelBarrierDeferredSuccessorStillMeansVictimIsBlocked`

Expected: PASS.

- [ ] **Step 6: Commit absence and discharge**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/StackFileWatcherTests.swift
git commit -m "fix: discharge watcher debt only after unblocked presence"
```

---

### Task 7: Implement Structured Write-Off Decisions and Current-Owner Grace

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.totalUnredeemedNanos(at:)`, `AccrualSegment.firstChargeNanos`, existing quiet-period and poll-interval configuration.
- Produces:
  - `func writeOffDecision(for:blockerName:victimLedger:nowNanos:) -> WriteOffDecision?`
  - write-off log using `WriteOffDecision`
  - property invariant N1

- [ ] **Step 1: Add a fast-write-off-with-predecessor-debt red test**

Add:

```swift
func testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately() {
    let blockerName = revisionName("00002")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("00001"), at: 0)
    ledger.pause(at: 29_500_000_000)
    ledger.startOrContinue(owner: RevisionKey("00002"), at: 30_000_000_000)

    let reducer = makeReducer(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000)

    let decision = reducer.writeOffDecision(
        for: RevisionKey("00002"),
        blockerName: blockerName,
        victimLedger: ledger,
        nowNanos: 60_500_000_000)

    XCTAssertEqual(decision?.blocker, RevisionKey("00002"))
    XCTAssertEqual(decision?.blockerNameForLog, blockerName)
    guard let attributedNanos = decision?.attributedNanos else {
        return XCTFail("expected a write-off decision")
    }
    XCTAssertLessThan(attributedNanos, 31_000_000_000)
    XCTAssertEqual(decision?.consumedSegments[RevisionKey("00001")], 29_500_000_000)
}
```

- [ ] **Step 2: Add a converging-successor grace red test**

Add:

```swift
func testSegmentModelDoesNotWriteOffConvergingFreshOwnerOnPredecessorDebt() {
    let blockerName = revisionName("00002")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("00001"), at: 0)
    ledger.pause(at: 29_500_000_000)
    ledger.startOrContinue(owner: RevisionKey("00002"), at: 30_000_000_000)

    var reducer = makeReducer(
        quietPeriodNanos: 5_000_000_000,
        pollIntervalNanos: 1_000_000_000)
    reducer.noteConvergingOwner(RevisionKey("00002"), at: 34_000_000_000)

    XCTAssertNil(reducer.writeOffDecision(
        for: RevisionKey("00002"),
        blockerName: blockerName,
        victimLedger: ledger,
        nowNanos: 35_000_000_000))
}
```

- [ ] **Step 3: Run write-off tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately`

Expected: FAIL because `writeOffDecision` is not structured or not visible to tests.

- [ ] **Step 4: Implement write-off decision calculation**

Replace Task 3's `totalWaitWriteOffCandidate(victimLedger:nowNanos:)` call with this test-visible method near the reducer's current write-off logic. Keep it `internal` under `@testable import` access:

```swift
func writeOffDecision(
    for blocker: RevisionKey,
    blockerName: String,
    victimLedger: VictimWaitLedger,
    nowNanos: UInt64
) -> WriteOffDecision? {
    let budget = max(
        30_000_000_000,
        configuration.quietPeriodNanos &* 10,
        configuration.pollIntervalNanos &* 5)

    let total = victimLedger.totalUnredeemedNanos(at: nowNanos)
    guard total >= budget else { return nil }
    guard currentOwnerGraceExpired(
        owner: blocker,
        in: victimLedger,
        nowNanos: nowNanos,
        budgetNanos: budget) else { return nil }

    var remaining = budget
    var consumed: [RevisionKey: UInt64] = [:]
    let orderedOwners = victimLedger.segments.keys.sorted { lhs, rhs in
        revisionOrder.orderedBefore(lhs, rhs)
    }
    for owner in orderedOwners {
        guard let segment = victimLedger.segments[owner], remaining > 0 else { continue }
        let available = segment.totalNanos(at: nowNanos)
        let amount = min(available, remaining)
        consumed[owner] = amount
        remaining -= amount
    }

    let attributedNanos: UInt64
    if let currentOwnerSegment = victimLedger.segments[blocker] {
        attributedNanos = currentOwnerSegment.totalNanos(at: nowNanos)
    } else {
        attributedNanos = 0
    }

    return WriteOffDecision(
        blocker: blocker,
        blockerNameForLog: blockerName,
        attributedNanos: attributedNanos,
        consumedSegments: consumed)
}
```

Add the grace check:

```swift
private func currentOwnerGraceExpired(
    owner: RevisionKey,
    in ledger: VictimWaitLedger,
    nowNanos: UInt64,
    budgetNanos: UInt64
) -> Bool {
    guard let segment = ledger.segments[owner] else { return false }
    let quiet = configuration.quietPeriodNanos
    let ceiling = segment.firstChargeNanos &+ budgetNanos &+ (quiet &* 4)
    if nowNanos >= ceiling { return true }
    if let renewedUntil = state.generation.ordering.ownerGraceUntil[owner],
       nowNanos < renewedUntil {
        return false
    }
    return nowNanos >= segment.firstChargeNanos &+ budgetNanos
}
```

Store convergence grace renewals in `RevisionOrderingState`:

```swift
var ownerGraceUntil: [RevisionKey: UInt64] = [:]
```

and add:

```swift
mutating func noteConvergingOwner(_ owner: RevisionKey, at nowNanos: UInt64) {
    state.generation.ordering.ownerGraceUntil[owner] = nowNanos &+ configuration.quietPeriodNanos
}
```

Connect the existing digest-progress or convergence-detection branch to `noteConvergingOwner(_:at:)`.

- [ ] **Step 5: Update write-off consumption and log**

When a decision is made, consume exactly the decision's segments and log both fields:

```swift
ledger.consume(decision.consumedSegments, at: batch.nowNanos)
log(.frameLost(
    name: decision.blockerNameForLog,
    reason: "blocked revision written off; own wait \(formatNanos(decision.attributedNanos)); predecessor debt \(formatConsumedSegments(decision.consumedSegments))"))
```

If the current log API uses plain strings, add:

```swift
private func formatConsumedSegments(_ segments: [RevisionKey: UInt64]) -> String {
    segments
        .sorted { lhs, rhs in revisionOrder.orderedBefore(lhs.key, rhs.key) }
        .map { "\($0.key.normalizedDigits)=\(formatNanos($0.value))" }
        .joined(separator: ", ")
}
```

- [ ] **Step 6: Add property invariant N1**

In `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`, add this invariant helper and call it from the existing randomized watcher sweep:

```swift
private func assertNoPrematureWriteOff(
    _ decision: WriteOffDecision,
    ledger: VictimWaitLedger,
    nowNanos: UInt64,
    budgetNanos: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let current = ledger.segments[decision.blocker] else { return }
    let ownAge = current.totalNanos(at: nowNanos)
    let predecessorDebt = decision.consumedSegments
        .filter { $0.key != decision.blocker }
        .values
        .reduce(0, &+)
    XCTAssertTrue(
        ownAge >= budgetNanos || predecessorDebt > 0,
        "blocker written off before its own budget without explicit predecessor debt",
        file: file,
        line: line)
}
```

- [ ] **Step 7: Run write-off and property tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelDoesNotWriteOffConvergingFreshOwnerOnPredecessorDebt`

Expected: PASS.

Run: `swift test --filter WatcherReducerPropertyTests`

Expected: PASS.

- [ ] **Step 8: Commit structured write-off**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift
git commit -m "fix: attribute watcher write-off debt by owner"
```

---

### Task 8: Port Driver-Faithful Batteries and Run Acceptance Gates

**Files:**
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`
- Modify: `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`

**Interfaces:**
- Consumes: complete segment model from Tasks 2-7.
- Produces: final proof that round-6, round-7, and round-8 scalar controls are red while the segment model is green.

- [ ] **Step 1: Add a scripted driver helper**

Add this helper inside `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`. It is driver-faithful because tests interact only by sending `.observe` and `.emissionFinished` commands; they do not inject reducer states the real driver cannot synthesize.

```swift
private struct ScriptedWatcherDriver {
    var reducer: WatcherReducer
    var emitted: [EmissionIntent] = []
    var logs: [String] = []

    init(configuration: WatcherReducerConfiguration) {
        reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1),
                    files: [:],
                    ordering: RevisionOrderingState()),
                lastEmittedDigestByName: [:]),
            configuration: configuration)
    }

    mutating func observe(_ entries: [FileObservation], at nowNanos: UInt64) -> [WatcherEffect] {
        apply(reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: entries,
            nowNanos: nowNanos))))
    }

    mutating func settleFirstEmission(_ outcome: EmissionResult.Outcome = .yielded) -> [WatcherEffect] {
        guard !emitted.isEmpty else { return [] }
        let intent = emitted.removeFirst()
        return apply(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: outcome))))
    }

    @discardableResult
    private mutating func apply(_ effects: [WatcherEffect]) -> [WatcherEffect] {
        for effect in effects {
            switch effect {
            case .emit(let intent):
                emitted.append(intent)
            case .log(let message):
                logs.append(message)
            }
        }
        return effects
    }
}
```

- [ ] **Step 2: Add driver-faithful d9 test**

Add:

```swift
func testSegmentModelDriver_d9FreshSuccessorGetsBudgetAfterOwnerEmission() {
    let oldBlocker = revisionName("00001")
    let freshBlocker = revisionName("00002")
    let victim = revisionName("00003")
    var driver = ScriptedWatcherDriver(configuration: makeConfiguration(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000))

    _ = driver.observe([
        observation(name: oldBlocker, revision: "00001", outcome: .digested(
            identity: makeIdentity(1), digest: "old", byteCount: makeIdentity(1).size)),
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3), digest: "victim", byteCount: makeIdentity(3).size)),
    ], at: 10)

    _ = driver.observe([
        observation(name: oldBlocker, revision: "00001", outcome: .identityUnchanged(identity: makeIdentity(1))),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .absent),
    ], at: 22_000_000_020)

    XCTAssertEqual(driver.emitted.map(\.candidate.name), [oldBlocker])
    _ = driver.settleFirstEmission(.yielded)

    _ = driver.observe([
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], at: 31_000_000_020)

    let ledger = driver.reducer.state.generation.ordering.victimLedgers[victim]
    XCTAssertEqual(ledger?.segments[RevisionKey("00002")]?.firstChargeNanos, 31_000_000_020)
    XCTAssertEqual(driver.reducer.state.generation.ordering.activeBlocker?.blocker, freshBlocker)
}
```

- [ ] **Step 3: Add driver-faithful e1/e7 tests**

Add:

```swift
func testSegmentModelDriver_unrelatedLowerEmissionDoesNotClearLiveOwnerDebt() {
    let lower = revisionName("00003")
    let blocker = revisionName("00005")
    let victim = revisionName("00006")
    var driver = ScriptedWatcherDriver(configuration: makeConfiguration(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000))

    _ = driver.observe([
        invalidRevision("00005"),
        observation(name: victim, revision: "00006", outcome: .digested(
            identity: makeIdentity(6), digest: "victim", byteCount: makeIdentity(6).size)),
    ], at: 10)

    _ = driver.observe([
        observation(name: lower, revision: "00003", outcome: .digested(
            identity: makeIdentity(3), digest: "lower", byteCount: makeIdentity(3).size)),
        invalidRevision("00005"),
        observation(name: victim, revision: "00006", outcome: .absent),
    ], at: 20_000_000_000)

    XCTAssertEqual(driver.emitted.map(\.candidate.name), [lower])
    _ = driver.settleFirstEmission(.yielded)

    XCTAssertNotNil(
        driver.reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("00005")],
        "emitting \(lower) did not resolve \(blocker)")
}
```

- [ ] **Step 4: Add driver-faithful h3/h4 tests**

Add:

```swift
func testSegmentModelDriver_sameBatchHandoffRedeemsBeforeSuccessorCharging() {
    let resolving = revisionName("00001")
    let successor = revisionName("00002")
    let victim = revisionName("00003")
    var driver = ScriptedWatcherDriver(configuration: makeConfiguration(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000))

    _ = driver.observe([
        invalidRevision("00001"),
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3), digest: "victim", byteCount: makeIdentity(3).size)),
    ], at: 0)

    _ = driver.observe([
        observation(name: resolving, revision: "00001", outcome: .digested(
            identity: makeIdentity(1), digest: "resolved", byteCount: makeIdentity(1).size)),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], at: 25_000_000_000)

    XCTAssertEqual(driver.emitted.map(\.candidate.name), [resolving])
    XCTAssertNil(driver.reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("00002")])

    _ = driver.settleFirstEmission(.yielded)
    _ = driver.observe([
        invalidRevision("00002"),
        observation(name: victim, revision: "00003", outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], at: 26_000_000_000)

    XCTAssertEqual(
        driver.reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("00002")]?.firstChargeNanos,
        26_000_000_000)
    XCTAssertEqual(driver.reducer.state.generation.ordering.activeBlocker?.blocker, successor)
}
```

- [ ] **Step 5: Add padding owner test**

Add:

```swift
func testSegmentModelDriver_paddingVariantRedeemsSameOwnerDuringAbsence() {
    let victim = revisionName("00008")
    var driver = ScriptedWatcherDriver(configuration: makeConfiguration(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000))

    _ = driver.observe([
        invalidRevision("7"),
        observation(name: victim, revision: "00008", outcome: .digested(
            identity: makeIdentity(8), digest: "victim", byteCount: makeIdentity(8).size)),
    ], at: 0)

    _ = driver.observe([
        observation(name: revisionName("007"), revision: "007", outcome: .digested(
            identity: makeIdentity(7), digest: "resolved", byteCount: makeIdentity(7).size)),
        observation(name: victim, revision: "00008", outcome: .absent),
    ], at: 20_000_000_000)

    _ = driver.settleFirstEmission(.yielded)

    XCTAssertNil(driver.reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("7")])
}
```

- [ ] **Step 6: Add pending-barrier bounded-loss test**

Add:

```swift
func testSegmentModelDriver_repeatedPendingLowerEmissionsOnlyDelayChargingByPollTicks() {
    let blocker = revisionName("00010")
    let victim = revisionName("00020")
    var driver = ScriptedWatcherDriver(configuration: makeConfiguration(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000))

    _ = driver.observe([
        invalidRevision("00010"),
        observation(name: victim, revision: "00020", outcome: .digested(
            identity: makeIdentity(20), digest: "victim", byteCount: makeIdentity(20).size)),
    ], at: 0)

    for (index, revision) in ["00001", "00002", "00003", "00004", "00005"].enumerated() {
        let identity = makeIdentity(Int64(index + 1))
        _ = driver.observe([
            observation(name: revisionName(revision), revision: revision, outcome: .digested(
                identity: identity,
                digest: "lower-\(revision)",
                byteCount: identity.size)),
            invalidRevision("00010"),
            observation(name: victim, revision: "00020", outcome: .identityUnchanged(identity: makeIdentity(20))),
        ], at: UInt64(index + 1) * 1_000_000_000)
        _ = driver.settleFirstEmission(.yielded)
    }

    let ledger = driver.reducer.state.generation.ordering.victimLedgers[victim]
    XCTAssertEqual(ledger?.segments[RevisionKey("00010")]?.firstChargeNanos, 0)
    XCTAssertEqual(driver.reducer.state.generation.ordering.activeBlocker?.blocker, blocker)
}
```

- [ ] **Step 7: Run driver-faithful watcher tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModelDriver_`

Expected: PASS.

- [ ] **Step 8: Run reconciled reducer and property batteries**

Run: `swift test --filter WatcherReducerTests`

Expected: PASS.

Run: `swift test --filter WatcherReducerPropertyTests`

Expected: PASS.

- [ ] **Step 9: Run full acceptance gates**

Run: `swift test`

Expected: PASS.

Run: `swift build -c release`

Expected: PASS.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 10: Commit final battery port**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md
git commit -m "test: prove watcher clock segment model"
```

---

## Final Review Checklist

- [ ] Every transition in `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md` maps to at least one committed test.
- [ ] `ChargingBlocker`, `VictimBlockingClock`, `victimClocks`, `startNanos`, and `deadlineNanos` are gone from production watcher ordering state.
- [ ] `lastEmittedDigestByName` remains per filename and survives folder-generation changes.
- [ ] `lastEmittedIdentity` or its current identity fast-path equivalent dies with folder generation.
- [ ] `RevisionKey` is the only owner key used for segment redemption and write-off consumption.
- [ ] The pending-emission barrier blocks successor charging, segment consumption, and write-off; it does not block file-state updates or emitted intent recording.
- [ ] The discharge predicate uses file states and numeric order, not `activeBlocker`, `pendingEmissionOwners`, or current charging state.
- [ ] Write-off logs separate own wait from predecessor debt.
- [ ] Driver-faithful tests cover d9, e1/e7, h3/h4, b1/W4-2a, padding variants, and pending-barrier bounded delay.
- [ ] The 3000-run timing-bound sweep is green with invariant N1.
- [ ] `swift test` passes.
- [ ] `swift build -c release` passes.
- [ ] `git diff --check` is clean.
