# Watcher Clock Segment Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision note (2026-07-30):** revised to resolve every finding in
> `docs/superpowers/reviews/2026-07-30-segment-plan-review.md`. The original
> fw6/fw7/fw8 probe batteries lived in a session scratchpad that no longer
> exists; Task 9 regenerates them as in-repo driver-faithful tests from the
> scenario descriptions in `docs/superpowers/reviews/2026-07-26-cold-review-round[4-6].md`
> and `docs/superpowers/reviews/2026-07-27-cold-review-round[7-8].md`.

**Goal:** Replace the watcher's scalar victim-blocking clock with per-owner accrual segments so numbered-revision holdback is bounded, attributable, and driver-faithful across emitted, vanished, absent, and padding-variant blockers.

**Architecture:** Keep the existing watcher reducer and driver protocol. The change is a narrow state-model swap inside `WatcherFileState.swift`: `VictimBlockingClock` becomes `VictimWaitLedger`, owner identity becomes normalized numeric `RevisionKey`, and write-off decisions consume structured per-owner debt after yielded settlements, tombstone pauses, discharge scans, and convergence grace are applied. Tests lead the change by reconciling the scalar-era batteries, then pinning each transition against real reducer and driver composition — including regenerated in-repo batteries and red/green control-snapshot counterfactuals.

**Tech Stack:** SwiftPM, Swift, XCTest, LiveAstroCore watcher reducer, existing `StackFileWatcher` filesystem integration tests, `git worktree` control snapshots.

## Global Constraints

- All work happens on a feature branch (`feature/watcher-segment-clocks`, created in Task 1). Never commit to `main`. The branch merges only after the external round-9 verification pass re-runs the battery and control counterfactuals; finishing this plan is not merge authorization.
- Preserve the existing watcher reducer architecture, file state machine, stat/digest gates, folder-generation rules, identity/digest verification, numeric ordering comparator, and tombstone synthesis.
- Do not change FITS completeness, digest policy, immutable vs. mutable stacker-output behavior, relay logic, OBS, SessionPipeline, app UI, packaging, notarization, or release artifacts.
- **The digest gate is real and every observe-driven test must respect it.** Under `.mutableStackerOutput` a brand-new file becomes `.ready` only on its **third** same-identity/same-digest sighting: sighting 1 → `.observing(stat:)` (`classify`, `case nil`), sighting 2 → `.digestPending(firstObservedNanos: t2)` (`reduceStableDigest`, `WatcherFileState.swift:904-951`), sighting 3 at `t3 ≥ t2 + quietPeriodNanos` → `.ready` + emission intent. `testNewMutableEntryRequiresStatStabilityThenDigestStability` pins this. A `.identityUnchanged` observation is a no-op for `.observing`/`.digestPending` files (`classify`, `.identityUnchanged` arm handles only `.settled`) — it keeps an already-`.ready` file present and re-emittable, but it can never make an unready file ready. Observe-driven tests that need a file to become ready must drive the three-sighting choreography; reducer-only tests may inject `.ready`/`.digestPending` states directly but must carry a `// Development probe:` comment and are not acceptance evidence (spec M10).
- Segment owners are normalized numeric revisions. Raw filenames are valid for logs and emission intents only.
- `RevisionKey` ordering must delegate to the existing digit-string numeric comparator; lexicographic ordering makes `"10"` sort before `"9"` and is a correctness bug. `RevisionKey` gets no `ExpressibleByStringLiteral` conformance: a stray raw-filename string literal must not silently become an owner key. Tests construct keys explicitly with `RevisionKey("7")`.
- Budget, grace, and ceiling are **only** read from the existing `WatcherReducer.blockingBudgetNanos`, `blockingGraceNanos`, and `blockingCeilingNanos` properties (`WatcherFileState.swift:219-238`). Never re-derive `max(30s, 10 × quiet, 5 × poll)` inline — the values match today and inline copies are drift hazards.
- Redemption fires only from `.emissionFinished` for the current generation when the outcome is `.yielded` and the candidate settles as `.emittedNow`. Redemption is owner-keyed (`redeemSegments(for:)`); there is no whole-map clearing on any emission path — broad emission-time clearing is failure mode #1 in spec §1.
- Observe-time emission intents never redeem debt. Pending intents install a narrow barrier that prevents successor-owner segment charging, consumption, or write-off until the intents settle or become non-yielded. The barrier defers ledger operations only; it must never skip the end-of-pass pause/discharge settlement.
- Vanished owners do not redeem. Their debt carries only while the victim remains continuously blocked or absent.
- Debt discharges after the victim's own yielded emission and after one full observe pass where the victim is present and unblocked.
- For discharge, unblocked is derived from the **classified observation batch** — the same evidence `orderedEffects` uses to pick a blocker: the victim is present in the batch and no batch-present lower revision participates in numbered ordering without a ready candidate. An `.invalid` observation with no prior `files` entry never enters `files` but is still an unready present blocker; a `files`-only predicate misses it and starves the victim. Do not derive unblocked from `BlockingEpisode`, segment charging, or the pending-emission barrier.
- Write-off requires enough unredeemed victim wait and expiration of the current owner's own convergence grace window (base tenure = one `blockingGraceNanos`; converging observations renew it; `firstChargeNanos + blockingCeilingNanos` is the hard cap).
- Write-off consumption **truncates**: consuming `n` nanoseconds from a segment holding more leaves the remainder as still-owed debt (see Task 2 for the §5.6 rationale). Zero-amount consumption entries never appear in a decision.
- Write-off logs must separate the current blocker's own attributed time from consumed predecessor debt. `WriteOffDecision.consumedSegments` holds predecessor segments only — the blocker's own key never appears in it.
- §5.6 escalation rule (spec): one blocked higher revision is enough to write off the head blocker. If any test turns out to assert a stricter all-victims threshold, stop and escalate as a spec conflict — do not silently change the threshold in either direction.
- Run driver-faithful composition tests before claiming convergence. Reducer-only injected states are development probes, not final acceptance evidence.

---

## File Structure

- Modify `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
  - Replace `ChargingBlocker` and `VictimBlockingClock` with `RevisionKey`, `AccrualSegment`, `VictimWaitLedger`, and `WriteOffDecision`.
  - Replace `RevisionOrderingState.victimClocks` with `victimLedgers`; add `pendingEmissionOwners` (Task 5) and `ownerGraceUntil` (Task 7).
  - Update `BlockingEpisode` to identify the current head blocker by raw filename plus normalized owner key, without storing scalar deadlines.
  - Replace the `reconcileActiveBlocker` clearing logic (all three `victimClocks.removeAll()` sites) with owner-keyed redemption (Task 4).
  - Replace the `orderedEffects` charging/write-off region wholesale (Task 7).
  - Keep the existing reducer command protocol and emission intent flow.
  - Keep `NumberedRevisionOrder` as the single numeric-order implementation.
- Modify `Sources/LiveAstroCore/Watch/StackFileWatcher.swift`
  - One line pair: the tombstone-synthesis union at lines 589-590 reads `reducer.state.generation.ordering.victimClocks.keys`; it must read `victimLedgers.keys` or nothing compiles after Task 3 and multi-scan absence pause breaks.
- Modify `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
  - Rename helper arguments from `victimClocks` to `victimLedgers`; rewrite every site that constructs or asserts the removed scalar types (enumerated in Task 3).
  - Add focused red-first tests for ledger primitives, yielded redemption, the d4 vanished-owner-carry counterexample, victim-own-emission discharge, pending-emission barrier, absent tombstones, discharge, convergence grace, write-off attribution, and map hygiene.
- Modify `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`
  - Rewrite the two `activeBlocker?.startNanos` assertions (Task 3), then add the driver-faithful ≥3000-run N1 sweep (Task 8).
- Create `Tests/LiveAstroCoreTests/WatcherSegmentBatteryTests.swift`
  - The regenerated driver-faithful battery (Task 9). Written **control-portable**: it uses only the stable reducer command/effect/file-state API that exists identically at `0ec11f8`, `6cb370a`, and `fe843eb` (verified: `git show <sha>:Sources/LiveAstroCore/Watch/WatcherFileState.swift` shows `case replaceGeneration`, `EmissionResult.Outcome.yielded/.rejected`, `FileObservation.observedAtNanos` at all three), so Task 10 can drop the same file into control worktrees.
- Create `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`
  - Records each scalar-era battery expectation that changes, the probe-regeneration provenance, and the observed control-snapshot red/green matrix.
- `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift` is **not edited** by this plan (resolving the review's scope-drift finding by removal, not by adding steps): it constructs no removed type — its only ordering-state access is a nil `activeBlocker` assertion at line 1049 — and Task 7 keeps the write-off log's leading clause (`"revision R blocked emissions for Ns … abandoning … (frame lost: name)"`) byte-compatible so its log-parsing tests (`testMutablePolicy_writeOffLogReportsEpisodeDuration_notLoneWallTime` and the `"abandoning"` filters) stay green. It is re-run, not modified, as the named H1/H2 hygiene gate in Task 11.

---

### Task 1: Create the Feature Branch and Reconcile Battery Expectations

**Files:**
- Create: `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`

**Interfaces:**
- Consumes: approved spec in `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md`; probe descriptions in the round-4..8 cold-review docs.
- Produces: the feature branch; reconciled test names and expected outcomes that later tasks must satisfy.

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feature/watcher-segment-clocks
```

Expected: `Switched to a new branch 'feature/watcher-segment-clocks'`. All commits in this plan land on this branch. **Merge discipline:** the branch is merged only after the external round-9 verification (independent battery + control re-run) returns green — completing Task 11 is not merge authorization.

- [ ] **Step 2: Write the reconciliation document**

Add this file exactly, then expand it only with concrete test names and observed control results discovered while executing Tasks 9-10:

```markdown
# Watcher Clock Battery Reconciliation

**Spec:** `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md`

The scalar-era fw6/fw7/fw8 batteries are LOST (session scratchpad gone). They are
regenerated in `Tests/LiveAstroCoreTests/WatcherSegmentBatteryTests.swift`, with each
probe re-derived from its written description in the round-4..8 review docs. This
document records (a) every expectation that changes under the segment model, (b) the
provenance of each regenerated probe, and (c) the observed control-snapshot matrix.
The reconciled expectations are the gate; stale scalar-era asserts are not.

## Reconciled expectations

| Probe | Source description | Old scalar-era expectation | Segment-model expectation | Spec clause |
|---|---|---|---|---|
| d1 present-victim redemption | round-8 C3 ("running clocks never reset on owner emission") | Successor inherits running accrual on every scalar build. | Owner emission redeems its running segment; successor gets its own full budget. | §5.1 |
| d2 paused-victim redemption | round-7 R7-1 / round-8 §5.1 "paused case" | Paused charge either wiped broadly (r6) or unclearable (r7). | Owner emission redeems its paused segment during victim absence. | §5.1 |
| d4 vanished-owner carry | round-8 M4, round-7 fix direction ("d4's vanished-owner carry is preserved") | Vanished-owner accrual either wiped by any emission or immortal. | A vanished owner never redeems; an unrelated successor's emission clears only its own segments. Consumption of the carried debt must name it in the log. | §§5.2, 5.4, 5.5 |
| d9 emitted-owner pause + same-batch successor | round-7 R7-1 repro; round-8 control table row 1 | Round 7 writes off the fresh successor ~9s after it appears. | Red on `6cb370a`, green on segment model: successor budget anchored at its own first charge. | §§4, 5.1 |
| e1 unrelated-lower emission | round-6 R6-1 / round-8 R8-1 (57s hold) | Emission of a transient lower occupant wipes the live stalled blocker's charge. | Red on `0ec11f8` and `fe843eb`; segment model bounds the hold: transient occupant redeems only its own interval. | §§5.1, 5.4, M7 |
| e7 adversarial arrivals | round-7 §closed list (36.0s), round-8 R8-1 ("grows linearly") | Hold grows with each adversarial lower arrival. | Red on `0ec11f8`/`fe843eb`; bounded by budget + per-cycle transient/barrier cost, non-compounding. | §§4, 5.3 |
| e9 bounded non-growing write-off | round-7 ("bounded at 48.0s, identical at 20/60/100 rewrite cycles") | Rewrite cycles could reset the budget forever. | Write-off bound is linear in cycle count with no compounding reset; identical shape at higher cycle counts. | §5.3 |
| h3 padding-rename-during-absence | round-8 R8-2 + control table (9.0s on all three) | Owner rename r_1→r_01 during victim absence makes its emission unmatchable. | Red on all three controls; `RevisionKey` normalization redeems across padding variants. | §3.1 |
| h4 same-batch present handoff | round-8 R8-3 + control table (8.0s on all three) | Ordered loop re-episodes before the old owner's emission settles. | Red on all three controls; the pending-emission barrier defers successor charging until settlement. | §4 |
| b1 / W4-2a unblocked discharge | round-4 W4-2a, round-5 "W4-2a fully closed" | (Closed since round 5 — green on all controls.) | One full present-and-unblocked pass discharges stale debt; a later fresh blocker gets a fresh budget. | §5.2 |
| c3 identity-churn victim | rounds 4-6 ("identity churn r_10↔r_010 … bounded (62.0s)") | Round 4/5: starves forever. | Padding-twin victims keep separate filename-keyed ledgers; write-off bounded ≈2× budget under 50% alternation. | §§3.1, 5.2 |
| S5 victim flicker | round-1 S5 via round-4 W4-2 ("absent 1 scan in 10 … never emitted in 800s") | Flicker destroys the clock; starvation. | Absence pauses; accrual resumes; write-off within ceiling of cumulative present-blocked time. | §§5.2, M1, M3 |
| C1 emission-during-unrelated-episode | round-8 C1 | Charged owner's emission while another episode is active leaves foreign accrual (20s write-off). | Redemption is owner-keyed and unconditional on episode state — covered by d1/d4 asserts. | §5.1 |
| C2 vanished-owner hijack + lying log | round-8 C2 (0.5s write-off, log claims 30s) | Brand-new blocker inherits 29.5s and the log lies. | Accelerated write-off is allowed only with the debt named: own-time clause stays honest (~1s), predecessor clause lists owner 1's carried debt. | §§5.4, 5.5, M9 |
| C3 running-clock non-reset | round-8 C3 | Fresh-budget property existed only for the paused case. | Uniform redemption: same rule for running and paused segments (= d1). | §5.1 |
| padding twins | round-6 ("padding twins get their own budgets") + round-7 R7-2 | Tie-break asymmetry; twins conflated or asymmetric. | Victims keyed by filename get separate ledgers; owners keyed by `RevisionKey` redeem symmetrically. | §3.1 |
| barrier cost | spec §4 (pending-emission barrier) | n/a (new mechanism) | Repeated pending lower emissions delay successor charging by at most the barrier passes — no accrual reset. | §4 |

## Control-snapshot matrix (filled in by Task 10)

Binding rows (round-8 control table): d9 red on `6cb370a` only; e1/e7 red on
`0ec11f8` and `fe843eb`; h3/h4 red on all three. All other probes: record the
observed result per snapshot with a one-line explanation (informative, not binding).
```

- [ ] **Step 3: Verify the reconciliation names every required probe**

Run: `rg -c "d1|d2|d4|d9|e1|e7|e9|h3|h4|b1|W4-2a|c3|S5|C1|C2|C3|padding|barrier" docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md`

Expected: a nonzero match count, and a manual check that every row of the reconciliation table names its probe id and source review doc. (Do not assert a fixed label count — the table is the source of truth, not a number.)

- [ ] **Step 4: Commit the reconciliation**

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
- Consumes: existing `NumberedRevisionOrder.revision(in:)` and `NumberedRevisionOrder.compare(_:_:)`.
- Produces:
  - `struct RevisionKey: Hashable, Equatable` (no `ExpressibleByStringLiteral` — see Global Constraints)
  - `struct AccrualSegment: Equatable`
  - `struct VictimWaitLedger: Equatable` with truncating `consume`
  - `struct WriteOffDecision: Equatable` (`consumedSegments` = predecessor debt only)
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
    // The §3.1 ban on lexicographic RevisionKey ordering, pinned as a sort:
    XCTAssertEqual(
        [RevisionKey("10"), RevisionKey("9")].sorted { order.orderedBefore($0, $1) },
        [RevisionKey("9"), RevisionKey("10")])
}

func testVictimWaitLedgerAccruesPausesRedeemsAndTotalsSegments() {
    let order = NumberedRevisionOrder(prefix: "live_stack")
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
    XCTAssertEqual(
        ledger.segments.keys.sorted { order.orderedBefore($0, $1) },
        [second])
}

func testVictimWaitLedgerConsumeTruncatesAndPreservesRemainder() {
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
    ledger.pause(at: 40)                                  // owner 1 holds 40
    ledger.startOrContinue(owner: RevisionKey("2"), at: 100)
    ledger.pause(at: 130)                                 // owner 2 holds 30

    ledger.consume([RevisionKey("1"): 25, RevisionKey("2"): 30], at: 200)

    XCTAssertEqual(ledger.segments[RevisionKey("1")]?.accruedNanos, 15,
                   "partial consumption truncates; the remainder is still owed")
    XCTAssertNil(ledger.segments[RevisionKey("2")],
                 "full consumption removes the segment")
    XCTAssertEqual(ledger.totalUnredeemedNanos(at: 200), 15)
}
```

- [ ] **Step 2: Run tests to verify the types are missing**

Run: `swift test --filter WatcherReducerTests/testRevisionKeyNormalizesPaddingAndUsesNumericOrdering`

Expected: FAIL (compile error) naming missing `RevisionKey`, `VictimWaitLedger`, or the new `NumberedRevisionOrder` methods.

- [ ] **Step 3: Add primitive types and numeric helpers**

Add near the top of `Sources/LiveAstroCore/Watch/WatcherFileState.swift` (the old clock structs at lines 30-64 are removed in Task 3, not here — Task 2 must leave the scanner compiling untouched):

```swift
struct RevisionKey: Hashable, Equatable {
    let normalizedDigits: String

    init(_ digits: String) {
        let stripped = digits.drop { $0 == "0" }
        normalizedDigits = stripped.isEmpty ? "0" : String(stripped)
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

    /// Write-off consumption TRUNCATES (§5.6 rationale): a single write-off consumes
    /// exactly the debt that justified it; any remainder is still-unresolved wait and
    /// keeps counting toward the NEXT blocker's write-off progress, so escalation
    /// stays bounded over unredeemed wait (M1) instead of granting the next blocker
    /// a silently discounted budget. (The alternative — deleting whole segments on
    /// partial consumption — would erase owed wait the decision never claimed.)
    mutating func consume(_ consumed: [RevisionKey: UInt64], at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        for (owner, amount) in consumed {
            guard var segment = segments[owner] else { continue }
            if segment.accruedNanos > amount {
                segment.accruedNanos -= amount
                segments[owner] = segment
            } else {
                segments.removeValue(forKey: owner)
            }
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

/// `consumedSegments` holds PREDECESSOR debt only — the blocker's own key must never
/// appear in it (M9: own time and inherited debt are separate facts). Zero-amount
/// entries are excluded at construction (Task 7).
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

Run: `swift test --filter WatcherReducerTests/testVictimWaitLedgerConsumeTruncatesAndPreservesRemainder`

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
- Modify: `Sources/LiveAstroCore/Watch/StackFileWatcher.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.startOrContinue(owner:at:)`, `pause(at:)`, `redeem(owner:)`, `totalUnredeemedNanos(at:)`.
- Produces:
  - `RevisionOrderingState.victimLedgers: [String: VictimWaitLedger]`
  - `BlockingEpisode(blocker:owner:victims:)`
  - a compile-clean reducer and driver using ledgers instead of `VictimBlockingClock`
  - an explicitly-defined **interim shape** whose remaining behavioral reds are enumerated below

- [ ] **Step 1: Write the failing generation-hygiene test**

Replace old scalar assertions with (note the command is `.replaceGeneration` — `.folderGenerationChanged` does not exist in `WatcherCommand`, `WatcherFileState.swift:192-196`):

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

    let effects = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 2)))

    XCTAssertTrue(effects.isEmpty)
    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
    XCTAssertEqual(reducer.state.lastEmittedDigestByName[victim], "victim")
}
```

- [ ] **Step 2: Run the new test to verify the old storage fails**

Run: `swift test --filter WatcherReducerTests/testGenerationChangeClearsVictimLedgersButKeepsDigestDedup`

Expected: FAIL (compile error) on missing `victimLedgers` / `victimLedgers:` helper parameter.

- [ ] **Step 3: Replace the storage types**

In `Sources/LiveAstroCore/Watch/WatcherFileState.swift`, delete `ChargingBlocker` and `VictimBlockingClock` (lines 30-64) and replace the ordering/episode declarations (lines 25-28 and 99-128) with:

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

(`pendingEmissionOwners` arrives in Task 5, `ownerGraceUntil` in Task 7 — do not add them yet.)

- [ ] **Step 4: Migrate the reducer to the interim Task-3 shape**

This is the explicitly-defined interim compile shape. It is scalar-free but intentionally incomplete: no grace, no barrier, no batch-derived discharge — those reds are enumerated at the end of this task and closed by Tasks 5-7.

**4a — `reconcileActiveBlocker` (lines 395-439):** rename `victimClocks` → `victimLedgers`. Keep the three `removeAll()` sites for now, each tagged `// TEMPORARY broad clear — replaced by owner-keyed redemption in Task 4`. Rewrite `clearPausedVictimClocksResolvedByEmission` (lines 427-439) as an owner-keyed clear (this becomes Task 4's `redeemSegments`):

```swift
private mutating func clearLedgersResolvedByEmission(of candidate: EmissionCandidate) {
    guard let emittedOwner = revisionOrder.revisionKey(in: candidate.name) else { return }
    for name in Array(state.generation.ordering.victimLedgers.keys) {
        state.generation.ordering.victimLedgers[name]?.redeem(owner: emittedOwner)
        if state.generation.ordering.victimLedgers[name]?.isEmpty == true {
            state.generation.ordering.victimLedgers[name] = nil
        }
    }
}
```

**4b — `applyMarkDrops` (line 503):** `state.generation.ordering.victimClocks[name] = nil` → `state.generation.ordering.victimLedgers[name] = nil` (a dropped-out-of-order victim is terminal; its ledger dies with it — M8).

**4c — `orderedEffects` charging region (lines 545-698), interim translation:**
- Line 547 (`revisionOrderingEnabled == false` branch): `victimClocks.removeAll()` → `victimLedgers.removeAll()` — this disabled-policy wipe is PERMANENT (ordering state is defined empty under the immutable policy); do not tag it. Line 567 (all-ready branch): `victimClocks.removeAll()` → `victimLedgers.removeAll()`, tagged `// TEMPORARY — Task 6 replaces with end-of-pass pause/discharge`.
- Derive the owner once per blocker: `let blockerOwner = blocker.revision.map(RevisionKey.init)`.
- The per-victim resume/inherit/create branches (lines 608-635) collapse to:

```swift
for victim in victimNames {
    guard let blockerOwner else { continue }
    state.generation.ordering.victimLedgers[victim, default: VictimWaitLedger()]
        .startOrContinue(owner: blockerOwner, at: nowNanos)
}
```

  The episode-inheritance branch (`active.victims.contains(victim)` seeding a clock from episode start/deadline) is deleted with no replacement — per spec §3.3 deadlines are derived from ledgers, and the round-6 hygiene ledger already flagged the branch as vestigial.
- Episode construction (lines 640-645 and 670-676) becomes a single:

```swift
state.generation.ordering.activeBlocker = blockerOwner.flatMap {
    BlockingEpisode(blocker: blockerName, owner: $0, victims: victimNames)
}
```

- The convergence-grace renewal loop (lines 654-666, `if blocker.isConverging { … deadlineNanos … }`) is **deleted** in the interim shape; Task 7 reintroduces grace via `noteConvergingOwner`. Tag the deletion site `// Convergence grace returns in Task 7 (ownerGraceUntil)`.
- The write-off predicate (lines 677-684) becomes:

```swift
guard victimNames.contains(where: { victim in
    guard let ledger = state.generation.ordering.victimLedgers[victim] else { return false }
    return totalWaitWriteOffCandidate(victimLedger: ledger, nowNanos: nowNanos)
}) else { return effects }
```

- The write-off application (lines 686-697) computes held time from ledgers **before** clearing:

```swift
let heldNanos = victimNames
    .compactMap { state.generation.ordering.victimLedgers[$0]?.totalUnredeemedNanos(at: nowNanos) }
    .max() ?? 0
state.generation.files[blockerName] = .writtenOff
for victim in victimNames {
    state.generation.ordering.victimLedgers[victim] = nil   // TEMPORARY — Task 7 consumes per decision
}
state.generation.ordering.activeBlocker = nil
let heldSeconds = Int((Double(heldNanos) / 1_000_000_000).rounded())
effects.append(.log(
    "revision \(blocker.revision ?? "") blocked emissions for \(heldSeconds)s "
    + "without completing — abandoning it; later revisions proceed "
    + "(frame lost: \(blockerName))"))
```

- Add the temporary total-wait gate so the interim shape compiles (reuses `blockingBudgetNanos` — never re-derive the formula):

```swift
// TEMPORARY Task-3 gate: total-wait only. Task 7 replaces this with
// writeOffDecision(for:blockerName:victimLedger:nowNanos:).
private func totalWaitWriteOffCandidate(
    victimLedger: VictimWaitLedger,
    nowNanos: UInt64
) -> Bool {
    victimLedger.totalUnredeemedNanos(at: nowNanos) >= blockingBudgetNanos
}
```

**4d — `retainVictimClocks` (lines 700-723)** becomes `retainVictimLedgers` with the same structure: for each ledger key not in `currentVictims`, if `shouldPauseVictimClock(named:behind:classifiedByName:)` holds (rename to `shouldPauseVictimLedger`; body unchanged — it is pure name/order/presence logic) then `state.generation.ordering.victimLedgers[name]?.pause(at: nowNanos)`, else `state.generation.ordering.victimLedgers[name] = nil` tagged `// TEMPORARY — Task 6 pauses instead of deleting outside the blocker path`. The `chargedUnder:` argument disappears (segments already know their owners).

- [ ] **Step 5: Fix the driver's tombstone synthesis**

In `Sources/LiveAstroCore/Watch/StackFileWatcher.swift` lines 589-590, the absent-name synthesis that keeps multi-scan-absent victims visible to the reducer (the round-5 R5-1 fix) reads the old map:

```swift
let absentCandidateNames = Set(reducer.state.generation.files.keys)
    .union(reducer.state.generation.ordering.victimClocks.keys)
```

becomes:

```swift
let absentCandidateNames = Set(reducer.state.generation.files.keys)
    .union(reducer.state.generation.ordering.victimLedgers.keys)
```

No other driver change. This is the only `StackFileWatcher.swift` edit in the whole plan.

- [ ] **Step 6: Rewrite every test-file site that touches the removed types**

Complete enumeration (from `rg -n "victimClocks|VictimBlockingClock|BlockingEpisode\(|startNanos|deadlineNanos|ChargingBlocker" Tests/`). Every site below must be rewritten in this step; `--filter` still compiles the whole test module, so Task 3 does not build until all of them are done.

`Tests/LiveAstroCoreTests/WatcherReducerTests.swift`:

1. `testRetainedDigestIsNeverGenerationOrderingEvidence` (lines 31-34): replace the episode `startNanos`/`deadlineNanos` asserts with
   `XCTAssertEqual(reducer.state.generation.ordering.victimLedgers[two]?.segments[RevisionKey("1")]?.firstChargeNanos, 10)` and
   `XCTAssertEqual(reducer.state.generation.ordering.victimLedgers[three]?.segments[RevisionKey("1")]?.firstChargeNanos, 10)`.
   The final write-off expectation (release `[two, three]` at `30_000_000_010`) is unchanged: owner 1's segment reaches 30s total there and grace is expired in the final Task-7 shape.
2. `testEqualNumericPaddingChurnDoesNotResetBlockingEpisodeClock` (line 139): `activeBlocker?.startNanos == 10` → `victimLedgers[victim]?.segments[RevisionKey("7")]?.firstChargeNanos == 10`. The write-off at `30_000_000_010` still holds: `RevisionKey("7") == RevisionKey("007")`, so the padded blocker continues the same segment.
3. `testRoleRoundTripStartsFreshEpisodeClock` (lines 194-222): both whole-episode equality asserts become
   `BlockingEpisode(blocker: revisionName("00002"), owner: RevisionKey("2"), victims: [revisionName("00003")])`; the `startNanos == 100` continuity asserts become
   `victimLedgers[revisionName("00003")]?.segments[RevisionKey("2")]?.firstChargeNanos == 100` (after pass 1) and, after pass 3, additionally `?.accruedNanos == 100` (segment 2 accrued 100ns across the pass-2 role swap, then resumed).
4. `testAggregateBlockerChurnDoesNotStarveContinuouslyHeldVictim` (lines 245, 255): first assert → `victimLedgers[victim]?.segments[RevisionKey("1")]?.firstChargeNanos == 10`; second assert → `victimLedgers[victim]?.segments[RevisionKey("2")]?.firstChargeNanos == 20` (per-owner anchors replace the inherited victim-start clock; the final release at `30_000_000_010` is unchanged because total unredeemed wait still reaches 30s there).
5. `testVictimDisappearancePausesClockAndReappearanceResumes` (lines 337, 349-351): line 337 → `victimLedgers[revisionName("00002")]?.segments[RevisionKey("1")]?.firstChargeNanos == 10`; lines 349-351 → assert pause preserved accrual instead of a shifted start:
   `victimLedgers[revisionName("00002")]?.segments[RevisionKey("1")]?.accruedNanos == 9_999_999_990` (charged 10→10_000_000_000, paused through the gap) after the pass at `100_000_000_000`; the write-off expectation at `120_000_000_011` is unchanged (resumed accrual reaches 30s at `120_000_000_010`).
6. `testVictimClockClearedWhenNoLongerBehindLiveBlocker` (lines 388, 400): line 388 keeps shape — `XCTAssertNil(...victimLedgers[victim], ...)` (discharge behavior; red until Task 6, see list below); line 400 → `victimLedgers[victim]?.segments[RevisionKey("1")]?.firstChargeNanos == 42_000_000_000`.
7. `testBlockerChurnNeverResetsEpisodeClock` (lines 458-468): the whole-episode equality still compiles (episodes are still `Equatable`) and remains valid — owner and victims are unchanged across churn. Additionally assert
   `victimLedgers[revisionName("00002")]?.segments[RevisionKey("1")]?.firstChargeNanos == 10` after the second pass.
8. `testConvergenceGraceClampsToCeilingAndWriteOffLogsEpisodeDuration` (lines 481-518): construct
   `BlockingEpisode(blocker: blocker, owner: RevisionKey("1"), victims: [revisionName("00002")])` and inject
   `victimLedgers: [revisionName("00002"): ledger]` where `ledger` has one segment `owner: RevisionKey("1"), firstChargeNanos: 0, accruedNanos: 0, runningSinceNanos: 0`. Delete the `deadlineNanos == ceiling` assert — do not replace it in Task 3 (`ownerGraceUntil` does not exist until Task 7; Task 7 Step 7 adds the `ownerGraceUntil`-based asserts when it rewrites this test; the behavioral write-off/log asserts stay and are expected-red from Task 3 until Task 7 — see list below). The final log text and `.writtenOff` expectations are unchanged.
9. `testVictimEmissionResultImmediatelyPrunesExhaustedEpisode` (lines 736-741, 753): episode equality → `BlockingEpisode(blocker: blocker, owner: RevisionKey("1"), victims: [victim])`; line 753 → `victimLedgers[revisionName("00004")]?.segments[RevisionKey("3")]?.firstChargeNanos == 30`.
10. `testUnrelatedClassicEmissionPreservesInvalidVictimEpisode` (lines 783-796): drop the `startNanos`/`deadlineNanos` asserts (785-787); keep blocker/victims asserts and the episode-preservation equality; add `victimLedgers[victim]?.segments[RevisionKey("1")]?.firstChargeNanos == 100` before and after the classic emission.
11. `testTerminalizingOneOfMultipleVictimsRetainsClockAndRemainingVictim` (lines 839-842): replace the episode start/deadline continuity asserts with
    `victimLedgers[remainingVictim]?.segments[RevisionKey("1")]?.firstChargeNanos == 100`.
12. `testObservationRefreshReplacesVictimSnapshotAndTearsDownWhenEmpty` (lines 867-870): same replacement —
    `victimLedgers[remainingVictim]?.segments[RevisionKey("1")]?.firstChargeNanos == 100`.
13. `testSuccessfulEmissionOfActiveBlockerPrunesInconsistentEpisode` (lines 895-899): `BlockingEpisode(blocker: blocker, owner: RevisionKey("1"), victims: [victim])`.
14. `testGenerationReplacementPreservesOnlyLatestDigestByName` (lines 930-934): the synthetic episode uses a classic name that can no longer own an episode; use `BlockingEpisode(blocker: revisionName("00001"), owner: RevisionKey("1"), victims: ["victim.fit"])` (the test only asserts nil-after-replacement).
15. `testNumberedEmissionClearsPausedVictimClockWhenEpisodeAlreadyDissolved` (lines 2133-2159): replace the `VictimBlockingClock`/`ChargingBlocker` construction with a ledger:
    `var ledger = VictimWaitLedger(); ledger.startOrContinue(owner: RevisionKey("1"), at: 10); ledger.pause(at: 20)` and pass `victimLedgers: [victim: ledger]`. The nil assert (2157) keeps its meaning: emission of owner 1 redeems the paused segment via the owner-keyed clear.
16. `testDriverEmissionClearsPausedClockChargedUnderEmittedOwnerBeforeFreshBlockerStarts` (lines 2161-2222): asserts at 2201/2208 keep shape with `victimLedgers`; the final fresh-budget assert (2219-2221) becomes
    `victimLedgers[victim]?.segments[RevisionKey("2")]?.firstChargeNanos == victimReturnNanos`.
17. `testLowerEmissionDoesNotClearPausedClockChargedUnderLaterBlocker` (lines 2224-2271): the two `victimClocks[victim]` asserts become `victimLedgers[victim]`; additionally pin the owner: `victimLedgers[victim]?.segments[RevisionKey("5")] != nil` after the lower emission settles.
18. Helper `makePopulatedWatcherState` (lines 2320-2324): `BlockingEpisode(blocker: revisionName("00001"), owner: RevisionKey("1"), victims: ["victim.fit"])`.
19. Helper `makeReducer` (lines 2348-2373): parameter `victimClocks: [String: VictimBlockingClock] = [:]` → `victimLedgers: [String: VictimWaitLedger] = [:]`; body `ordering.victimClocks = victimClocks` → `ordering.victimLedgers = victimLedgers`.

`Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`:

20. `testRoleRoundTripsPreserveOnlyContinuousVictimClocks` (lines 367-369, 396-398): the pass-1 assert becomes
    `reducer.state.generation.ordering.victimLedgers[revisionName(victimRevision)]?.segments[RevisionKey(returningRevision)]?.firstChargeNanos == firstTime`; the pass-3 continuity assert becomes the same expression still equal to `firstTime` (the returning blocker's segment survives the role swap; `RevisionKey(returningRevision)` is unpadded so no normalization surprises).

- [ ] **Step 7: Build and run the focused reducer tests**

Run: `swift test --filter WatcherReducerTests`

Expected: the module **compiles** (grep-verify no survivor first: `rg -n "VictimBlockingClock|ChargingBlocker|victimClocks|deadlineNanos" Sources Tests` → only hits allowed are in docs). Failures are limited to this exact expected-red list, each closed by the named later task:

- `testGenerationChangeClearsVictimLedgersButKeepsDigestDedup` — PASS already (this task).
- `testConvergenceGraceClampsToCeilingAndWriteOffLogsEpisodeDuration` — RED (interim shape has no grace: write-off fires at `ceiling − 2` instead of holding to `ceiling`). Closed by Task 7.
- `testVictimClockClearedWhenNoLongerBehindLiveBlocker` — RED (interim retains-or-deletes semantics may keep the ledger; the discharge scan lands in Task 6). Closed by Task 6.
- `testVictimDisappearancePausesClockAndReappearanceResumes` — RED if the interim `retainVictimLedgers` delete path fires for the absent victim while the blocker is present-but-pause-eligible; verify the pause branch holds it, otherwise Task 6 closes it.
- Property test `testRoleRoundTripsPreserveOnlyContinuousVictimClocks` — PASS (pause path covers the absent-lower-blocker roundtrip).

Any failure outside this list means the storage replacement is incomplete — finish it before moving on.

- [ ] **Step 8: Commit storage migration**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Sources/LiveAstroCore/Watch/StackFileWatcher.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift
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
  - a fully replaced `reconcileActiveBlocker` with **zero** `removeAll()` sites
  - victim's-own-emission ledger discharge (a stated Global Constraint, implemented and tested here)

- [ ] **Step 1: Add the d9 redemption red test**

```swift
func testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission() {
    // Development probe: reducer-only, injected .ready states.
    // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_d9_* (Task 9).
    let ownerName = revisionName("00001")
    let victim = revisionName("00002")
    let owner = RevisionKey("1")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: owner, at: 0)
    ledger.pause(at: 22_000_000_000)

    let ownerCandidate = makeCandidate(
        name: ownerName,
        identity: makeIdentity(1),
        digest: "owner",
        kind: .numbered(revision: "00001"))
    var reducer = makeReducer(
        files: [ownerName: .ready(ownerCandidate)],
        victimLedgers: [victim: ledger])

    let effects = reducer.reduce(.emissionFinished(EmissionResult(
        intent: EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: ownerCandidate),
        outcome: .yielded)))

    XCTAssertTrue(effects.isEmpty)
    XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                 "owner 1's paused segment was the only debt; redemption empties and removes the ledger")
}
```

- [ ] **Step 2: Add the d4 anti-removeAll red test**

This is the test the review demanded: it fails if any emission path resurrects broad clearing. The active episode names the emitting blocker, so the scalar-era site-1 `removeAll()` would wipe the vanished owner's debt.

```swift
func testSegmentModel_d4VanishedOwnerDebtSurvivesUnrelatedSuccessorEmission() {
    // Development probe: reducer-only, injected states. d4 provenance: round-8 M4
    // ("vanished = still owed"), round-7 fix direction ("d4's vanished-owner carry
    // is preserved"). Driver-faithful acceptance: WatcherSegmentBatteryTests.test_d4_*.
    let successorName = revisionName("00002")
    let victim = revisionName("00005")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)   // owner 1 later vanished
    ledger.pause(at: 10_000_000_000)                          // 10s unresolved debt
    ledger.startOrContinue(owner: RevisionKey("2"), at: 12_000_000_000)
    ledger.pause(at: 20_000_000_000)                          // owner 2 holds 8s

    let successorCandidate = makeCandidate(
        name: successorName,
        identity: makeIdentity(2),
        digest: "successor",
        kind: .numbered(revision: "00002"))
    var reducer = makeReducer(
        files: [
            successorName: .ready(successorCandidate),
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(5),
                digest: "victim",
                kind: .numbered(revision: "00005")))
        ],
        activeBlocker: BlockingEpisode(
            blocker: successorName,
            owner: RevisionKey("2"),
            victims: [victim]),
        victimLedgers: [victim: ledger])

    _ = reducer.reduce(.emissionFinished(EmissionResult(
        intent: EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: successorCandidate),
        outcome: .yielded)))

    XCTAssertNil(
        reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("2")],
        "the emitting owner's own segment is redeemed")
    XCTAssertEqual(
        reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("1")]?.accruedNanos,
        10_000_000_000,
        "the vanished owner's carried debt must survive an unrelated successor's emission (d4)")
}
```

- [ ] **Step 3: Add the non-redemption and own-emission tests**

```swift
func testSegmentModelRejectedEmissionDoesNotRedeemDebt() {
    // Development probe: reducer-only, injected states.
    let ownerName = revisionName("00001")
    let victim = revisionName("00002")
    let owner = RevisionKey("1")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: owner, at: 0)
    ledger.pause(at: 10_000_000_000)

    let ownerCandidate = makeCandidate(
        name: ownerName,
        identity: makeIdentity(1),
        digest: "owner",
        kind: .numbered(revision: "00001"))
    var reducer = makeReducer(
        files: [ownerName: .ready(ownerCandidate)],
        victimLedgers: [victim: ledger])

    _ = reducer.reduce(.emissionFinished(EmissionResult(
        intent: EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: ownerCandidate),
        outcome: .rejected)))

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim]?.segments[owner],
                    "a rejected emission is not stream progress and redeems nothing")
}

func testSegmentModelVictimOwnYieldedEmissionClearsItsLedger() {
    // Development probe: reducer-only, injected states. §5.2: "The victim's own
    // successful emission also clears its ledger."
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)   // stale predecessor debt
    ledger.pause(at: 9_000_000_000)

    let victimCandidate = makeCandidate(
        name: victim,
        identity: makeIdentity(3),
        digest: "victim",
        kind: .numbered(revision: "00003"))
    var reducer = makeReducer(
        files: [victim: .ready(victimCandidate)],
        victimLedgers: [victim: ledger])

    _ = reducer.reduce(.emissionFinished(EmissionResult(
        intent: EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: victimCandidate),
        outcome: .yielded)))

    XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                 "the victim emitted — no owed wait can explain any future hold")
}
```

- [ ] **Step 4: Run the new tests to verify red/green split**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d4VanishedOwnerDebtSurvivesUnrelatedSuccessorEmission`

Expected: FAIL — the interim Task-3 `removeAll()` at the blocker-emission site wipes owner 1's debt.

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission`

Expected: PASS already (the Task-3 owner-keyed `clearLedgersResolvedByEmission` covers the episode-nil path) — it is retained as the pinned d9 reducer shape.

Run: `swift test --filter WatcherReducerTests/testSegmentModelRejectedEmissionDoesNotRedeemDebt`

Expected: PASS. A failure showing redemption on `.rejected` is the regression this task guards against.

Run: `swift test --filter WatcherReducerTests/testSegmentModelVictimOwnYieldedEmissionClearsItsLedger`

Expected: PASS already — the interim Task-3 rename of line 396 (`victimLedgers[candidate.name] = nil`) already clears the emitting victim's own ledger before the episode guard. Retained as the pinned shape so Step 5's wholesale replacement cannot regress it.

- [ ] **Step 5: Replace `reconcileActiveBlocker` wholesale**

Replace the entire `reconcileActiveBlocker(afterEmitting:)` (interim Task-3 version, originally `WatcherFileState.swift:395-439`) and delete `clearLedgersResolvedByEmission` — its body becomes `redeemSegments(for:)`. This is the complete replacement; all three former `victimClocks.removeAll()` sites (blocker-emitted at :404, victims-emptied at :413, high-water dissolution at :424) become episode-only dissolutions, because ledgers are now touched exclusively by (a) owner-keyed redemption and (b) the victim's own emission:

```swift
private mutating func reconcileActiveBlocker(afterEmitting candidate: EmissionCandidate) {
    // (b) The emitting victim's own ledger discharges (§5.2): its emission proves
    // no owed wait explains any future hold on it.
    state.generation.ordering.victimLedgers[candidate.name] = nil

    // (a) Owner-keyed redemption — uniform over running and paused segments (§5.1).
    // This replaces every scalar-era removeAll(): other owners' unredeemed segments
    // (vanished predecessors, still-live blockers) must survive this emission (d4, e1).
    if let owner = revisionOrder.revisionKey(in: candidate.name) {
        redeemSegments(for: owner)
    }

    guard var episode = state.generation.ordering.activeBlocker else { return }

    if candidate.name == episode.blocker {
        state.generation.ordering.activeBlocker = nil   // episode over; ledgers already settled above
        return
    }

    if episode.victims.contains(candidate.name) {
        state.generation.ordering.activeBlocker =
            episode.removeVictim(named: candidate.name) ? episode : nil
    }

    guard state.generation.ordering.activeBlocker != nil,
          revisionOrder.revision(in: candidate.name) != nil,
          let blockerRevision = revisionOrder.revision(in: episode.blocker),
          let mark = derivedRevisionHighWater,
          revisionOrder.compare(blockerRevision, mark) != .orderedDescending
    else { return }
    state.generation.ordering.activeBlocker = nil       // episode inconsistent with the derived mark
}

private mutating func redeemSegments(for owner: RevisionKey) {
    for victim in Array(state.generation.ordering.victimLedgers.keys) {
        state.generation.ordering.victimLedgers[victim]?.redeem(owner: owner)
        if state.generation.ordering.victimLedgers[victim]?.isEmpty == true {
            state.generation.ordering.victimLedgers[victim] = nil
        }
    }
    // Task 7 extends this function with ownerGraceUntil[owner] = nil (M8 hygiene).
}
```

**Insertion sites and generation gating:** `reconcileActiveBlocker(afterEmitting:)` is already called from both `.emissionFinished` settlement paths — the settled-replacement path (`WatcherFileState.swift:283-306`) and the top-level ready path (`:307-326`) — and both sit behind the arm's generation guard (`guard result.intent.generation == state.generation.id`, `:280`) and behind the `.settled(.emittedNow)` assignment. Redemption therefore inherits exactly the required gate: current generation + `.yielded` + really settled `.emittedNow`. No new call sites; verify both existing ones still call it after this edit.

- [ ] **Step 6: Run redemption tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d4VanishedOwnerDebtSurvivesUnrelatedSuccessorEmission`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelRejectedEmissionDoesNotRedeemDebt`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelVictimOwnYieldedEmissionClearsItsLedger`

Expected: PASS.

Run: `rg -n "removeAll" Sources/LiveAstroCore/Watch/WatcherFileState.swift`

Expected: no hits inside `reconcileActiveBlocker`; the only remaining `victimLedgers.removeAll()` hits inside `orderedEffects` are the permanent disabled-policy wipe (formerly line 547) and the one Task-3 TEMPORARY site (formerly line 567), which Task 6 removes.

- [ ] **Step 7: Commit redemption**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "fix: redeem watcher debt by owner on yielded emission"
```

---

### Task 5: Add the Pending-Emission Barrier

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: yielded-only redemption from Task 4.
- Produces:
  - `RevisionOrderingState.pendingEmissionOwners: Set<RevisionKey>`
  - observe-pass deferral of successor charging, consumption, and write-off while predecessor intents are unsettled
  - barrier structured so it can never skip end-of-pass ledger settlement (it pauses and breaks; it does not `return`)

- [ ] **Step 1: Add the h4 reducer red test**

```swift
func testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles() {
    // Development probe: reducer-only, injected .ready states (an unready file cannot
    // become ready and emit in a single sighting — see Global Constraints).
    // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_h4_*.
    let resolving = revisionName("00001")
    let victim = revisionName("00003")
    let resolvingCandidate = makeCandidate(
        name: resolving,
        identity: makeIdentity(1),
        digest: "resolved",
        kind: .numbered(revision: "00001"))
    var reducer = makeReducer(files: [
        resolving: .ready(resolvingCandidate),
        victim: .ready(makeCandidate(
            name: victim,
            identity: makeIdentity(3),
            digest: "victim",
            kind: .numbered(revision: "00003")))
    ])

    let effects = observeBatch([
        observation(name: resolving, revision: "00001",
                    outcome: .identityUnchanged(identity: makeIdentity(1))),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003",
                    outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], nowNanos: 1_000, reducer: &reducer)

    XCTAssertEqual(emittedNames(in: effects), [resolving])
    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty,
                  "successor charging is barrier-deferred in the intent's own pass")
    XCTAssertEqual(reducer.state.generation.ordering.pendingEmissionOwners, [RevisionKey("1")])
}
```

- [ ] **Step 2: Add the settlement-resumes-charging test**

```swift
func testSegmentModelSuccessorChargesAfterPendingEmissionSettles() {
    // Development probe: reducer-only, injected .ready states.
    let resolving = revisionName("00001")
    let successor = revisionName("00002")
    let victim = revisionName("00003")
    let resolvingCandidate = makeCandidate(
        name: resolving,
        identity: makeIdentity(1),
        digest: "resolved",
        kind: .numbered(revision: "00001"))
    var reducer = makeReducer(files: [
        resolving: .ready(resolvingCandidate),
        victim: .ready(makeCandidate(
            name: victim,
            identity: makeIdentity(3),
            digest: "victim",
            kind: .numbered(revision: "00003")))
    ])

    let effects = observeBatch([
        observation(name: resolving, revision: "00001",
                    outcome: .identityUnchanged(identity: makeIdentity(1))),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003",
                    outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], nowNanos: 1_000, reducer: &reducer)
    guard case .emit(let intent) = effects.first else {
        return XCTFail("expected the resolving revision's emission intent")
    }

    _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: .yielded)))
    XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty,
                  "settlement removes the pending owner for every terminal outcome")

    _ = observeBatch([
        observation(name: resolving, revision: "00001",
                    outcome: .identityUnchanged(identity: makeIdentity(1))),
        invalidRevision("00002"),
        observation(name: victim, revision: "00003",
                    outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], nowNanos: 2_000, reducer: &reducer)

    XCTAssertEqual(
        reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("2")]?.firstChargeNanos,
        2_000)
    XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, successor)
}
```

- [ ] **Step 3: Run barrier tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles`

Expected: FAIL — `pendingEmissionOwners` does not exist yet and successor charging happens in the same observe pass.

- [ ] **Step 4: Implement the barrier**

Add to `RevisionOrderingState`:

```swift
var pendingEmissionOwners: Set<RevisionKey> = []
```

**Recording (in `orderedEffects`):** extend the nested `appendIntent` helper with a `pendingOwners: inout Set<RevisionKey>` parameter and record every numbered intent's owner:

```swift
func appendIntent(
    named name: String,
    state: WatcherState,
    to effects: inout [WatcherEffect],
    intentNames: inout Set<String>,
    pendingOwners: inout Set<RevisionKey>
) {
    guard intentNames.insert(name).inserted else { return }
    guard let candidate = readyCandidate(in: state.generation.files[name]) else { return }
    effects.append(.emit(EmissionIntent(
        generation: state.generation.id,
        candidate: candidate)))
    if let owner = revisionOrder.revisionKey(in: candidate.name) {
        pendingOwners.insert(owner)
    }
}
```

At the top of `orderedEffects` declare `var pendingOwners = state.generation.ordering.pendingEmissionOwners`, thread it through every `appendIntent` call, and write it back with `state.generation.ordering.pendingEmissionOwners = pendingOwners` immediately after the pre-blocker emission loop (so the barrier check below sees both prior-pass unsettled owners and this pass's intents) and again before the function returns.

**Settlement (in the `.emissionFinished` arm):** at the top of the arm, after the existing generation guard (`:280`), remove the owner for **all** terminal outcomes:

```swift
if let owner = revisionOrder.revisionKey(in: result.intent.candidate.name) {
    state.generation.ordering.pendingEmissionOwners.remove(owner)
}
```

(Stale-generation intents never linger: `.replaceGeneration` swaps in a fresh `RevisionOrderingState`, and the Task-7 hygiene test asserts the map empties.)

**Barrier check (in `orderedEffects`, on the blocker branch, before any charging/consumption/write-off):**

```swift
private func hasPendingLowerOwner(before owner: RevisionKey) -> Bool {
    state.generation.ordering.pendingEmissionOwners.contains { pending in
        revisionOrder.orderedBefore(pending, owner)
    }
}
```

used as (interim wiring; Task 7's wholesale block keeps exactly this shape):

```swift
if hasPendingLowerOwner(before: blockerOwner) {
    for victim in victimNames {
        state.generation.ordering.victimLedgers[victim]?.pause(at: nowNanos)
    }
    return effects   // interim; Task 6 turns this into `break blockerScan` so the
                     // end-of-pass pause/discharge settlement still runs
}
```

The pause matters: a segment left running through a barrier pass would silently extend under the deferred owner, which is exactly what the barrier forbids. The barrier defers ledger operations only — file-state updates, intent recording, and mark drops proceed normally.

- [ ] **Step 5: Run barrier tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelSuccessorChargesAfterPendingEmissionSettles`

Expected: PASS.

- [ ] **Step 6: Commit barrier**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "fix: defer watcher successor charging across pending emissions"
```

---

### Task 6: Implement Absence, Tombstone, and Batch-Derived Unblocked Discharge

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.pause(at:)`, the driver tombstone union already migrated in Task 3 (StackFileWatcher.swift:589-590 — the driver keeps synthesizing `.absent` observations for every `victimLedgers` key, so multi-scan-absent victims stay visible to the reducer; no further driver work).
- Produces:
  - `private func isPresentAndUnblocked(name:classifiedByName:) -> Bool` — batch-derived (this exact name and signature; the interface list and the definition must not drift)
  - an end-of-pass pause/discharge settlement that runs on **every** exit path of `orderedEffects`
  - removal of the remaining TEMPORARY `victimLedgers.removeAll()` site (formerly line 567; the disabled-policy wipe stays)

- [ ] **Step 1: Add the b1 discharge red test**

```swift
func testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass() {
    // Development probe: reducer-only, injected ledger. b1/W4-2a provenance: round-4
    // W4-2a (stale clocks age while unblocked), round-5 "W4-2a fully closed".
    // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_b1_*.
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
    ledger.pause(at: 29_000_000_000)
    var reducer = makeReducer(victimLedgers: [victim: ledger])

    // One full pass: victim present (first .digested sighting → .observing is enough —
    // discharge needs presence, not readiness), and no lower revision in the batch.
    _ = observeBatch([
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3),
            digest: "victim",
            byteCount: makeIdentity(3).size))
    ], nowNanos: 30_000_000_000, reducer: &reducer)

    XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                 "a present-and-unblocked pass discharges stale debt (§5.2)")
}
```

- [ ] **Step 2: Add the B2 regression test — an `.invalid` lower with no files entry still blocks**

This is the review's code-B2 counterexample: an `.invalid` observation with no prior state never enters `files` (`classify`, `.invalid` arm, `WatcherFileState.swift:767-777`) yet is an unready present blocker in `orderedEffects`. A `files`-only discharge predicate would judge the victim unblocked and wipe its debt every pass — unbounded starvation.

```swift
func testSegmentModelInvalidLowerWithoutFilesEntryStillBlocksDischarge() {
    // Development probe: reducer-only, injected ledger.
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("2"), at: 0)
    ledger.pause(at: 10_000_000_000)
    var reducer = makeReducer(victimLedgers: [victim: ledger])

    _ = observeBatch([
        invalidRevision("00002"),   // present, unready, and NEVER in state.generation.files
        observation(name: victim, revision: "00003", outcome: .digested(
            identity: makeIdentity(3),
            digest: "victim",
            byteCount: makeIdentity(3).size))
    ], nowNanos: 11_000_000_000, reducer: &reducer)

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                    "an invalid lower revision is batch-present and unready — the victim is blocked")
}

func testSegmentModelBarrierDeferredSuccessorStillMeansVictimIsBlocked() {
    // Development probe: reducer-only, injected states. The barrier is not an
    // unblocked signal (§5.2): an unready lower revision keeps the victim blocked
    // even while charging is barrier-deferred.
    let victim = revisionName("00003")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
    ledger.pause(at: 10_000_000_000)
    var ordering = RevisionOrderingState(activeBlocker: nil)
    ordering.victimLedgers = [victim: ledger]
    ordering.pendingEmissionOwners = [RevisionKey("1")]
    var reducer = WatcherReducer(
        state: WatcherState(
            generation: GenerationState(
                id: FolderGeneration(rawValue: 1),
                files: [victim: .ready(makeCandidate(
                    name: victim,
                    identity: makeIdentity(3),
                    digest: "victim",
                    kind: .numbered(revision: "00003")))],
                ordering: ordering),
            lastEmittedDigestByName: [:]),
        configuration: makeConfiguration())

    _ = observeBatch([
        invalidRevision("00002"),
        observation(name: victim, revision: "00003",
                    outcome: .identityUnchanged(identity: makeIdentity(3))),
    ], nowNanos: 11_000_000_000, reducer: &reducer)

    XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim])
}
```

- [ ] **Step 3: Run discharge tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass`

Expected: FAIL — the interim shape has no discharge scan (the TEMPORARY `removeAll()` on the no-blocker branch either wipes tombstones too broadly or, for this single-file batch shape, never runs where needed).

- [ ] **Step 4: Implement the batch-derived predicate and the end-of-pass settlement**

**4a — the predicate.** Blockedness derives from the classified batch — the same evidence `orderedEffects` uses (`isPresent` + `participatesInNumberedOrdering` + `readyCandidate == nil`):

```swift
/// Discharge predicate (§5.2). Present and unblocked is a batch/file-state/numeric-order
/// fact: the victim appeared present in THIS batch and no batch-present lower revision
/// is unready. Never derived from BlockingEpisode, charging, or pendingEmissionOwners.
private func isPresentAndUnblocked(
    name: String,
    classifiedByName: [String: ClassifiedObservation]
) -> Bool {
    guard let victim = classifiedByName[name],
          victim.isPresent,
          let victimRevision = victim.revision
    else { return false }
    for item in classifiedByName.values {
        guard item.observation.name != name,
              item.isPresent,
              let revision = item.revision,
              revisionOrder.orderedBefore(
                  (name: item.observation.name, revision: revision),
                  (name: name, revision: victimRevision)),
              participatesInNumberedOrdering(state.generation.files[item.observation.name]),
              readyCandidate(in: state.generation.files[item.observation.name]) == nil
        else { continue }
        return false
    }
    return true
}
```

**4b — restructure `orderedEffects` exits.** Label the blocker loop `blockerScan: while true` and convert every `return effects` inside it (the all-ready branch, the lone-blocker branch, the barrier branch from Task 5, and the no-decision fallthrough) into `break blockerScan`. Delete the TEMPORARY `victimLedgers.removeAll()` site (formerly line 567, the all-ready branch). The `revisionOrderingEnabled == false` branch keeps its `removeAll()` — ordering state is defined empty under the immutable policy — and additionally clears `pendingEmissionOwners`. After the loop, before `return effects`, add the settlement that runs on **every** path:

```swift
// End-of-pass ledger settlement (M3 tombstones + §5.2 discharge). Runs on every
// exit from blockerScan — including barrier deferrals and write-off passes.
let currentVictims = state.generation.ordering.activeBlocker?.victims ?? []
for name in Array(state.generation.ordering.victimLedgers.keys) {
    if currentVictims.contains(name) { continue }          // charging this pass
    if isPresentAndUnblocked(name: name, classifiedByName: classifiedByName) {
        state.generation.ordering.victimLedgers[name] = nil // discharge (§5.2)
    } else {
        state.generation.ordering.victimLedgers[name]?.pause(at: nowNanos)  // tombstone / not charged
    }
}
```

A ledger key with no observation in the batch hits the `pause` arm (`classifiedByName[name] == nil` → not present) — that is the reducer-side tombstone; the driver guarantees such names reappear as `.absent` next scan via the Task-3 union. With this settlement in place, delete `retainVictimLedgers` and `shouldPauseVictimLedger` — the end-of-pass loop subsumes both (retention = pause; deletion only via discharge, redemption, own emission, mark drop, or generation swap).

- [ ] **Step 5: Run discharge tests**

Run: `swift test --filter WatcherReducerTests/testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelInvalidLowerWithoutFilesEntryStillBlocksDischarge`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests/testSegmentModelBarrierDeferredSuccessorStillMeansVictimIsBlocked`

Expected: PASS.

Run: `swift test --filter WatcherReducerTests`

Expected: only the Task-3 enumerated reds that name Task 7 remain (`testConvergenceGraceClampsToCeilingAndWriteOffLogsEpisodeDuration`); `testVictimClockClearedWhenNoLongerBehindLiveBlocker` and `testVictimDisappearancePausesClockAndReappearanceResumes` are now green.

- [ ] **Step 6: Commit absence and discharge**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "fix: discharge watcher debt only after unblocked presence"
```

---

### Task 7: Structured Write-Off Decisions, Current-Owner Grace, and Map Hygiene

**Files:**
- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`

**Interfaces:**
- Consumes: `VictimWaitLedger.totalUnredeemedNanos(at:)`, `consume(_:at:)`, `AccrualSegment.firstChargeNanos`, `blockingBudgetNanos`/`blockingGraceNanos`/`blockingCeilingNanos`, the barrier and settlement from Tasks 5-6.
- Produces:
  - `func writeOffDecision(for:blockerName:victimLedger:nowNanos:) -> WriteOffDecision?` (test-visible under `@testable`)
  - `RevisionOrderingState.ownerGraceUntil: [RevisionKey: UInt64]` + `noteConvergingOwner(_:at:)` wired to the real convergence signal
  - the wholesale replacement of the `orderedEffects` charging/write-off region (the old lines 599-697)
  - compile-correct write-off logging (`effects.append(.log(String))`) separating own time from predecessor debt
  - cleanup transitions + generation-swap/quiescence assertions for `pendingEmissionOwners` and `ownerGraceUntil`
  - `var writeOffDecisionHookForTesting: ((WriteOffDecision, UInt64) -> Void)?` — the Task-8 sweep's observation point

- [ ] **Step 1: Add the predecessor-debt attribution red test (recomputed values)**

Config: `quietPeriodNanos: 100_000_000`, `pollIntervalNanos: 1_000_000_000` → budget `30e9` (floor dominates), grace `1e8`, ceiling `30.4e9`.

Ledger: owner 1 charged 0 → 29.5e9 then paused (vanished predecessor, 29.5s owed); owner 2 charged from 30e9, running. Decision asked at `now = 35e9`:
- total = 29.5e9 + 5e9 = 34.5e9 ≥ 30e9 budget ✓
- owner 2's grace: firstCharge 30e9, no renewal → expired at 30.1e9 ✓
- attributed (own) = 5e9; predecessor need = 30e9 − 5e9 = 25e9 → consume 25e9 of owner 1's 29.5e9 (truncating; 4.5e9 remains owed).

```swift
func testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately() {
    let blockerName = revisionName("00002")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
    ledger.pause(at: 29_500_000_000)
    ledger.startOrContinue(owner: RevisionKey("2"), at: 30_000_000_000)

    let reducer = makeReducer(
        quietPeriodNanos: 100_000_000,
        pollIntervalNanos: 1_000_000_000)

    let decision = reducer.writeOffDecision(
        for: RevisionKey("2"),
        blockerName: blockerName,
        victimLedger: ledger,
        nowNanos: 35_000_000_000)

    XCTAssertEqual(decision?.blocker, RevisionKey("2"))
    XCTAssertEqual(decision?.blockerNameForLog, blockerName)
    XCTAssertEqual(decision?.attributedNanos, 5_000_000_000)
    XCTAssertEqual(decision?.consumedSegments, [RevisionKey("1"): 25_000_000_000])
    XCTAssertNil(decision?.consumedSegments[RevisionKey("2")],
                 "the blocker's own segment must never appear under predecessor debt (M9)")
}
```

- [ ] **Step 2: Add the non-vacuous converging-grace red test (recomputed values)**

Config: `quietPeriodNanos: 1_000_000_000`, `pollIntervalNanos: 1_000_000_000` → budget `30e9`, grace `1e9`, ceiling `34e9`. Same ledger shape. At `now = 34.5e9` the total is 29.5e9 + 4.5e9 = **34e9 ≥ 30e9 budget — the total gate passes**, so the decision is nil *only* because the renewed grace window (renewal at 34e9 → holds until 35e9) is still open; at `now = 35e9` with no further renewal the same call returns a decision. This closes the review's I6 vacuity: the same test proves grace was the only gate, and pins that grace merely delays rather than kills the write-off.

```swift
func testSegmentModelDoesNotWriteOffConvergingFreshOwnerInsideRenewedGrace() {
    let blockerName = revisionName("00002")
    var ledger = VictimWaitLedger()
    ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
    ledger.pause(at: 29_500_000_000)
    ledger.startOrContinue(owner: RevisionKey("2"), at: 30_000_000_000)

    var reducer = makeReducer(
        quietPeriodNanos: 1_000_000_000,
        pollIntervalNanos: 1_000_000_000)
    reducer.noteConvergingOwner(RevisionKey("2"), at: 34_000_000_000)

    XCTAssertNil(
        reducer.writeOffDecision(
            for: RevisionKey("2"),
            blockerName: blockerName,
            victimLedger: ledger,
            nowNanos: 34_500_000_000),
        "total (34e9) exceeds budget (30e9) — only the renewed grace defers the decision")

    let afterGrace = reducer.writeOffDecision(
        for: RevisionKey("2"),
        blockerName: blockerName,
        victimLedger: ledger,
        nowNanos: 35_000_000_000)
    XCTAssertEqual(afterGrace?.attributedNanos, 5_000_000_000)
    XCTAssertEqual(afterGrace?.consumedSegments, [RevisionKey("1"): 25_000_000_000])
}
```

- [ ] **Step 3: Add the churn-does-not-renew-grace test**

The real convergence signal is `ClassifiedObservation.isConverging`, which is true only when `classify` observes a same-digest re-sighting inside the quiet period — the `return true` guards in `reduceStableDigest` (`WatcherFileState.swift:928-930`) and `reduceSettledReplacementDigest` (`:877-879`). Non-converging churn (`.invalid`, `.unstable`, digest changes) must not touch `ownerGraceUntil`.

```swift
func testSegmentModelNonConvergingChurnDoesNotRenewOwnerGrace() {
    // Development probe: reducer-only, injected victim state.
    let blocker = revisionName("00001")
    let victim = revisionName("00002")
    var reducer = makeReducer(files: [
        victim: .ready(makeCandidate(
            name: victim,
            identity: makeIdentity(2),
            digest: "victim",
            kind: .numbered(revision: "00002")))
    ])

    // Invalid churn: never converging.
    for tick in 1...3 {
        _ = observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: UInt64(tick) * 1_000, reducer: &reducer)
    }
    XCTAssertNil(reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")],
                 "invalid churn is not convergence and renews nothing")

    // Genuine convergence: same digest re-sighted inside the quiet period (quiet=100).
    _ = observeBatch([
        observation(name: blocker, revision: "00001", outcome: .digested(
            identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 4_000, reducer: &reducer)             // -> .observing
    _ = observeBatch([
        observation(name: blocker, revision: "00001", outcome: .digested(
            identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 5_000, reducer: &reducer)             // -> .digestPending(first=5_000)
    _ = observeBatch([
        observation(name: blocker, revision: "00001", outcome: .digested(
            identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 5_050, reducer: &reducer)             // same digest, 50 < quiet(100) -> converging

    XCTAssertEqual(reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")],
                   5_050 + 100,
                   "a converging observation renews the CURRENT owner's grace by one quiet period")
}
```

- [ ] **Step 4: Run the write-off tests to verify failure**

Run: `swift test --filter WatcherReducerTests/testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately`

Expected: FAIL — `writeOffDecision` does not exist yet (the interim gate is `totalWaitWriteOffCandidate`).

- [ ] **Step 5: Implement the decision, the grace window, and the hook**

Add to `RevisionOrderingState`:

```swift
var ownerGraceUntil: [RevisionKey: UInt64] = [:]
```

Add to `WatcherReducer` (replacing `totalWaitWriteOffCandidate`, which is deleted):

```swift
/// Test-only observation point for the N1 sweep (Task 8). Nil in production.
var writeOffDecisionHookForTesting: ((WriteOffDecision, UInt64) -> Void)?

/// §§5.4-5.6. Nil when the ledger lacks budget-worth of unredeemed wait, or when
/// the current owner is still inside its own convergence grace window.
/// `consumedSegments` = predecessor debt only, oldest owner first, truncating,
/// zero-amount entries excluded. Budget/grace/ceiling reuse the reducer properties.
func writeOffDecision(
    for blocker: RevisionKey,
    blockerName: String,
    victimLedger: VictimWaitLedger,
    nowNanos: UInt64
) -> WriteOffDecision? {
    let budget = blockingBudgetNanos
    guard victimLedger.totalUnredeemedNanos(at: nowNanos) >= budget else { return nil }
    guard currentOwnerGraceExpired(owner: blocker, in: victimLedger, nowNanos: nowNanos)
    else { return nil }

    let attributedNanos = victimLedger.segments[blocker]?.totalNanos(at: nowNanos) ?? 0
    var remaining = budget > attributedNanos ? budget - attributedNanos : 0
    var consumed: [RevisionKey: UInt64] = [:]
    let predecessors = victimLedger.segments.keys
        .filter { $0 != blocker }
        .sorted { revisionOrder.orderedBefore($0, $1) }
    for owner in predecessors {
        guard remaining > 0, let segment = victimLedger.segments[owner] else { continue }
        let amount = min(segment.totalNanos(at: nowNanos), remaining)
        guard amount > 0 else { continue }   // zero-amount entries pollute the decision map
        consumed[owner] = amount
        remaining -= amount
    }
    return WriteOffDecision(
        blocker: blocker,
        blockerNameForLog: blockerName,
        attributedNanos: attributedNanos,
        consumedSegments: consumed)
}

/// §5.4: base tenure is one grace period from the owner's own first charge;
/// converging observations renew it (ownerGraceUntil); the hard cap is the
/// owner-anchored ceiling. Predecessor debt never shortens a fresh owner's grace,
/// and grace never rewrites predecessor segments.
private func currentOwnerGraceExpired(
    owner: RevisionKey,
    in ledger: VictimWaitLedger,
    nowNanos: UInt64
) -> Bool {
    guard let segment = ledger.segments[owner] else { return false }
    let ceiling = segment.firstChargeNanos &+ blockingCeilingNanos
    if nowNanos >= ceiling { return true }
    if let renewedUntil = state.generation.ordering.ownerGraceUntil[owner],
       nowNanos < renewedUntil {
        return false
    }
    return nowNanos >= segment.firstChargeNanos &+ blockingGraceNanos
}

mutating func noteConvergingOwner(_ owner: RevisionKey, at nowNanos: UInt64) {
    state.generation.ordering.ownerGraceUntil[owner] = nowNanos &+ blockingGraceNanos
}
```

**Convergence call site (exact):** the old per-victim deadline-renewal loop lived in `orderedEffects` at `WatcherFileState.swift:654-666` under `if blocker.isConverging { … }`, fed by `classify`'s converging return from `reduceStableDigest:928-930` / `reduceSettledReplacementDigest:877-879`. Its replacement is the single line `noteConvergingOwner(blockerOwner, at: nowNanos)` in the wholesale block below — renewing the **current** owner only.

**Hygiene transitions (M8):** extend `redeemSegments(for:)` (Task 4) with `state.generation.ordering.ownerGraceUntil[owner] = nil`; the write-off block below clears the written-off owner's entry; and the end-of-pass settlement (Task 6) gains, after the pause/discharge loop:

```swift
// ownerGraceUntil holds entries only for owners that still matter: live segments
// or the current head blocker. Everything else (vanished never-charged owners,
// discharged debt) is pruned so the map is empty at quiescence (H2).
let liveOwners = Set(state.generation.ordering.victimLedgers.values.flatMap { $0.segments.keys })
let headOwner = state.generation.ordering.activeBlocker?.owner
state.generation.ordering.ownerGraceUntil = state.generation.ordering.ownerGraceUntil
    .filter { liveOwners.contains($0.key) || $0.key == headOwner }
```

- [ ] **Step 6: Replace the orderedEffects charging/write-off region wholesale**

This replaces the remainder of the old lines 599-697 (blocker-name/charging/episode/convergence/deadline/write-off) inside `blockerScan`. Together with Tasks 5-6 this is the complete final body of the loop after `victimStart`/`victimNames` are derived:

```swift
let blockerName = blocker.observation.name
guard let blockerOwner = blocker.revision.map(RevisionKey.init) else {
    break blockerScan   // unreachable: `numbered` items always parse a revision
}

state.generation.ordering.activeBlocker = BlockingEpisode(
    blocker: blockerName,
    owner: blockerOwner,
    victims: victimNames)   // nil (episode-less) when victimNames is empty — lone blockers own nothing

guard !victimNames.isEmpty else { break blockerScan }

// Pending-emission barrier (§4): defer open/extend/consume/write-off while a
// lower owner's intent is unsettled. Pause so no segment silently extends.
if hasPendingLowerOwner(before: blockerOwner) {
    for victim in victimNames {
        state.generation.ordering.victimLedgers[victim]?.pause(at: nowNanos)
    }
    break blockerScan
}

// Charge (§4 step 5): one running segment per victim, keyed by the current owner.
for victim in victimNames {
    state.generation.ordering.victimLedgers[victim, default: VictimWaitLedger()]
        .startOrContinue(owner: blockerOwner, at: nowNanos)
}

// Convergence grace (§5.4): renew the CURRENT owner only.
if blocker.isConverging {
    noteConvergingOwner(blockerOwner, at: nowNanos)
}

// Write-off (§§5.5-5.6): ONE blocked victim with a justified decision suffices.
var justified: (victim: String, decision: WriteOffDecision)?
for victim in victimNames.sorted() {
    guard let ledger = state.generation.ordering.victimLedgers[victim],
          let decision = writeOffDecision(
              for: blockerOwner,
              blockerName: blockerName,
              victimLedger: ledger,
              nowNanos: nowNanos)
    else { continue }
    justified = (victim, decision)
    break
}
guard let (justifyingVictim, decision) = justified else { break blockerScan }

writeOffDecisionHookForTesting?(decision, nowNanos)
state.generation.files[blockerName] = .writtenOff
var consumption = decision.consumedSegments
consumption[decision.blocker] = decision.attributedNanos   // the terminal owner's own segment dies with it
state.generation.ordering.victimLedgers[justifyingVictim]?.consume(consumption, at: nowNanos)
if state.generation.ordering.victimLedgers[justifyingVictim]?.isEmpty == true {
    state.generation.ordering.victimLedgers[justifyingVictim] = nil
}
// Other victims keep their segments: the written-off owner never emitted, so per
// §5.2 their attributed wait stays owed; the next pass discharges them if the
// write-off left them unblocked.
state.generation.ordering.activeBlocker = nil
state.generation.ordering.ownerGraceUntil[decision.blocker] = nil

let heldSeconds = Int((Double(decision.attributedNanos) / 1_000_000_000).rounded())
var message = "revision \(blocker.revision ?? decision.blocker.normalizedDigits) "
    + "blocked emissions for \(heldSeconds)s without completing — abandoning it; "
    + "later revisions proceed (frame lost: \(decision.blockerNameForLog))"
if !decision.consumedSegments.isEmpty {
    message += "; consumed predecessor debt: "
        + formatConsumedSegments(decision.consumedSegments)
}
effects.append(.log(message))
continue blockerScan   // re-derive the next blocker; newly unblocked ready files emit this pass
```

with the formatters (plain `String` effects — `WatcherEffect` is `case log(String)`, `WatcherFileState.swift:213-216`; there is no `log(.frameLost(...))` and no pre-existing `formatNanos`):

```swift
private func formatSeconds(_ nanos: UInt64) -> String {
    String(format: "%.1fs", Double(nanos) / 1_000_000_000)
}

private func formatConsumedSegments(_ segments: [RevisionKey: UInt64]) -> String {
    segments
        .sorted { revisionOrder.orderedBefore($0.key, $1.key) }
        .map { "\($0.key.normalizedDigits)=\(formatSeconds($0.value))" }
        .joined(separator: ", ")
}
```

The leading clause (`"revision R blocked emissions for Ns without completing — abandoning it; later revisions proceed (frame lost: name)"`) is byte-compatible with the scalar-era log so `StackFileWatcherTests`' log-parsing tests keep passing; `heldSeconds` now derives from `attributedNanos` — the blocker's own time — never episode age, and predecessor debt appears only in its own clearly-labeled clause (M9).

- [ ] **Step 7: Rewrite the convergence-ceiling test to its Task-3-promised final form**

`testConvergenceGraceClampsToCeilingAndWriteOffLogsEpisodeDuration` (red since Task 3): with the Task-3 injected ledger (owner 1, firstCharge 0, running since 0; quiet=10 → budget 30e9, ceiling 30e9+40), the first observe at `ceiling − 2` is a converging sighting (same pending digest inside quiet) → assert
`reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")] == ceiling - 2 + 10` (replaces the old `deadlineNanos == ceiling` assert); no write-off (renewed grace holds, `ceiling − 2 < ceiling`). The second observe at `ceiling` → grace hard-capped by the owner-anchored ceiling → write-off fires; the expected log is unchanged (`"revision 00001 blocked emissions for 30s …"` — attributed = ceiling ns ≈ 30.00000004s → rounds to 30; no predecessor clause since `consumedSegments` is empty).

- [ ] **Step 8: Add generation-swap and quiescence hygiene tests**

```swift
func testGenerationChangeClearsBarrierAndGraceState() {
    // Development probe: reducer-only, injected state. M8: everything ordering-scoped
    // dies with the generation.
    var ordering = RevisionOrderingState(activeBlocker: nil)
    ordering.victimLedgers = [revisionName("00002"): VictimWaitLedger(
        segments: [RevisionKey("1"): AccrualSegment(
            owner: RevisionKey("1"), firstChargeNanos: 0, accruedNanos: 5, runningSinceNanos: nil)],
        pausedAtNanos: 5)]
    ordering.pendingEmissionOwners = [RevisionKey("1")]
    ordering.ownerGraceUntil = [RevisionKey("1"): 99]
    var reducer = WatcherReducer(
        state: WatcherState(
            generation: GenerationState(
                id: FolderGeneration(rawValue: 1), files: [:], ordering: ordering),
            lastEmittedDigestByName: ["keep.fit": "digest"]),
        configuration: makeConfiguration())

    XCTAssertTrue(reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 2))).isEmpty)

    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
    XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty)
    XCTAssertTrue(reducer.state.generation.ordering.ownerGraceUntil.isEmpty)
    XCTAssertEqual(reducer.state.lastEmittedDigestByName["keep.fit"], "digest")
}

func testOrderingMapsEmptyAtQuiescenceAfterWriteOffAndEmissions() {
    // Development probe: reducer-only, injected .ready victim. Drives a full
    // blocked -> write-off -> victim-emits -> all-settled cycle and asserts H2:
    // every ordering map is empty once nothing is blocked or pending.
    let victim = revisionName("00002")
    let victimCandidate = makeCandidate(
        name: victim, identity: makeIdentity(2), digest: "victim",
        kind: .numbered(revision: "00002"))
    var reducer = makeReducer(files: [victim: .ready(victimCandidate)])

    _ = observeBatch([
        invalidRevision("00001"),
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 10, reducer: &reducer)
    let released = observeBatch([
        invalidRevision("00001"),
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 30_000_000_010, reducer: &reducer)
    guard case .emit(let intent)? = released.last(where: {
        if case .emit = $0 { return true }; return false
    }) else { return XCTFail("write-off must release the victim's intent") }
    _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: .yielded)))
    _ = observeBatch([
        observation(name: victim, revision: "00002",
                    outcome: .identityUnchanged(identity: makeIdentity(2))),
    ], nowNanos: 31_000_000_010, reducer: &reducer)

    XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty, "H2: no leaked ledgers")
    XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty, "H2: no leaked barrier owners")
    XCTAssertTrue(reducer.state.generation.ordering.ownerGraceUntil.isEmpty, "H2: no leaked grace entries")
    XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
}
```

- [ ] **Step 9: Run the Task-7 suite**

Run: `swift test --filter WatcherReducerTests`

Expected: PASS — including the four new tests, the Step-7 rewrite, and every previously-enumerated Task-3 red. No expected failures remain in this file.

- [ ] **Step 10: Commit structured write-off**

```bash
git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift
git commit -m "fix: attribute watcher write-off debt by owner"
```

---

### Task 8: Driver-Faithful Randomized Sweep With Two-Condition Invariant N1

**Files:**
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`

**Interfaces:**
- Consumes: `writeOffDecisionHookForTesting` (Task 7), `blockingBudgetNanos`/`blockingGraceNanos`/`blockingCeilingNanos`, `SplitMix64` (already in this file).
- Produces: a ≥3000-run randomized sweep, driver-faithful at the command level (only `.observe`/`.emissionFinished`/`.replaceGeneration` — no injected reducer states), asserting the **two-condition** N1 from the spec's acceptance gate: *no blocker is written off before first charge + budget, EXCEPT where the decision explicitly consumed unredeemed predecessor debt AND the current owner's own convergence grace had expired.* The old 1,000-transition reducer-only loops remain as development probes; this sweep is the acceptance instrument.

**Decision observation mechanism (chosen and defined):** the test-only hook `writeOffDecisionHookForTesting: ((WriteOffDecision, UInt64) -> Void)?` added in Task 7, fired at the exact commit point of every write-off. It observes without injecting: the sweep still drives only real commands. (The alternative — parsing structured logs — was rejected: log seconds are rounded, and N1 needs exact `firstChargeNanos`/renewal values, which the sweep snapshots from `reducer.state` before each observe.)

- [ ] **Step 1: Add the sweep**

```swift
func testDriverFaithfulSweepHoldsTimingBoundInvariantN1() {
    // ≥3000 runs across both digest policies (1500 × 2). Commands only; the hook
    // observes decisions; per-pass snapshots supply exact anchors for N1.
    let runsPerPolicy = 1_500
    for policy in [StackFileWatcher.DigestPolicy.mutableStackerOutput, .immutableAfterPublish] {
        var immutableDecisions = 0
        for run in 0..<runsPerPolicy {
            var generator = SplitMix64(seed: Self.seed ^ UInt64(run) &* 0x9E37)
            var reducer = WatcherReducer(
                state: WatcherState(
                    generation: GenerationState(
                        id: FolderGeneration(rawValue: 1),
                        files: [:],
                        ordering: RevisionOrderingState(activeBlocker: nil)),
                    lastEmittedDigestByName: [:]),
                configuration: WatcherReducerConfiguration(
                    digestPolicy: policy,
                    filePrefix: "live_stack",
                    quietPeriodNanos: 100_000_000,
                    pollIntervalNanos: 1_000_000_000))

            // Per-pass snapshots taken BEFORE each observe: exact N1 anchors.
            var snapshotLedgers: [String: VictimWaitLedger] = [:]
            var snapshotGrace: [RevisionKey: UInt64] = [:]
            var pendingNow: UInt64 = 0
            var violations: [String] = []
            reducer.writeOffDecisionHookForTesting = { decision, now in
                let budget: UInt64 = 30_000_000_000     // budget at this config; cross-checked below
                let grace: UInt64 = 100_000_000
                let ceiling: UInt64 = 30_400_000_000
                let firstCharge = snapshotLedgers.values
                    .compactMap { $0.segments[decision.blocker]?.firstChargeNanos }
                    .min() ?? pendingNow                 // segment opened this pass
                if now < firstCharge &+ budget {
                    if decision.consumedSegments.isEmpty {
                        violations.append("early write-off without explicit predecessor debt at \(now)")
                    }
                    let renewal = snapshotGrace[decision.blocker] ?? 0
                    let graceEdge = min(firstCharge &+ ceiling,
                                        max(firstCharge &+ grace, renewal))
                    if now < graceEdge {
                        violations.append("write-off inside the owner's own grace at \(now)")
                    }
                }
            }
            XCTAssertEqual(reducer.blockingBudgetNanos, 30_000_000_000)
            XCTAssertEqual(reducer.blockingGraceNanos, 100_000_000)
            XCTAssertEqual(reducer.blockingCeilingNanos, 30_400_000_000)

            var digestsByName: [String: String] = [:]
            var now: UInt64 = 0
            var unsettled: [EmissionIntent] = []
            for _ in 0..<120 {
                now &+= 1_000_000_000
                pendingNow = now
                snapshotLedgers = reducer.state.generation.ordering.victimLedgers
                snapshotGrace = reducer.state.generation.ordering.ownerGraceUntil

                var entries: [FileObservation] = []
                for value in 1...6 {
                    let revision = String(value)
                    let name = revisionName(revision)
                    let identity = makeIdentity(Int64(value))
                    let roll = generator.next() % 100
                    let outcome: ObservationOutcome
                    switch roll {
                    case ..<15: outcome = .absent
                    case ..<40: outcome = .invalid
                    case ..<50: outcome = .unstable(identity: identity)
                    case ..<60:
                        digestsByName[name] = "churn-\(generator.next() % 1_000)"
                        outcome = .digested(
                            identity: identity,
                            digest: digestsByName[name]!,
                            byteCount: identity.size)
                    default:
                        let digest = digestsByName[name] ?? "stable-\(value)"
                        digestsByName[name] = digest
                        outcome = .digested(
                            identity: identity, digest: digest, byteCount: identity.size)
                    }
                    entries.append(makeObservation(name: name, revision: revision, outcome: outcome))
                }
                let effects = reduce(entries, nowNanos: now, reducer: &reducer)
                for effect in effects {
                    if case .emit(let intent) = effect { unsettled.append(intent) }
                    if case .log(let line) = effect, policy == .immutableAfterPublish,
                       line.contains("abandoning") {
                        immutableDecisions += 1
                    }
                }
                while !unsettled.isEmpty {
                    let intent = unsettled.removeFirst()
                    let outcome: EmissionResult.Outcome =
                        generator.next() % 5 == 0 ? .rejected : .yielded
                    _ = reducer.reduce(.emissionFinished(EmissionResult(
                        intent: intent, outcome: outcome)))
                }
                XCTAssertTrue(violations.isEmpty,
                              "seed=\(Self.seed) run=\(run) policy=\(policy): \(violations)")
            }
        }
        if policy == .immutableAfterPublish {
            XCTAssertEqual(immutableDecisions, 0,
                           "ordering (and write-off) is mutable-policy-only")
        }
    }
}
```

- [ ] **Step 2: Run the sweep red-first sanity check**

Before Task 7's code exists this test cannot compile; it is added only now, so the red-first evidence is the **N1-sensitivity check**: temporarily weaken `currentOwnerGraceExpired` to `return true` (one-line local edit, not committed), run the sweep, and confirm it reports `write-off inside the owner's own grace` violations. Revert the edit.

Run: `swift test --filter WatcherReducerPropertyTests/testDriverFaithfulSweepHoldsTimingBoundInvariantN1`

Expected: FAIL with grace violations while the weakening edit is in place; PASS after reverting.

If the weakened run reports NO violations (possible: with 1s ticks vs 0.1s quiet the random walk may produce no converging observations, so the grace conjunct may never be the deciding factor), do not proceed on faith — weaken the budget gate instead (`totalUnredeemed >= budget` → `return true`), confirm the sweep reports premature write-offs (proving the harness observes decisions at all), then revert both edits before continuing.

- [ ] **Step 3: Run the full property suite**

Run: `swift test --filter WatcherReducerPropertyTests`

Expected: PASS (including the Task-3 rewritten role-roundtrip test).

- [ ] **Step 4: Commit the sweep**

```bash
git add Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift
git commit -m "test: add watcher N1 timing-bound sweep"
```

---

### Task 9: Regenerate the Driver-Faithful Battery In-Repo

**Files:**
- Create: `Tests/LiveAstroCoreTests/WatcherSegmentBatteryTests.swift`
- Modify: `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md` (record any expectation discovered to differ while writing tests)

**Interfaces:**
- Consumes: the complete segment model from Tasks 2-7.
- Produces: the regenerated fw6/fw7/fw8-descendant battery. Every test is **driver-faithful** (commands only, no injected reducer state) and **control-portable** (only stable API: `WatcherReducer`, `WatcherCommand`, `WatcherEffect`, `FileState.writtenOff`, `EmissionResult` — all present identically at `0ec11f8`/`6cb370a`/`fe843eb`). Assertions are observables only: emitted names, `"abandoning"` logs and their timing, log clause contents, `.writtenOff` file states. Segment-state assertions live in `WatcherReducerTests` (Tasks 4-7), not here — that split is what lets Task 10 run this exact file on scalar control snapshots.

Every test carries a header comment citing its probe id and source review doc. Shared config throughout: `quietPeriodNanos: 100_000_000`, `pollIntervalNanos: 1_000_000_000` → budget 30e9, ceiling 30.4e9. Poll ticks are 1e9, so a brand-new file becomes ready on its third consecutive same-digest sighting (tick gap 1e9 ≥ quiet 1e8 — see Global Constraints).

- [ ] **Step 1: Add the scripted driver and helpers**

```swift
import XCTest
@testable import LiveAstroCore

/// Regenerated watcher battery. The original fw6/fw7/fw8 probe sources are lost;
/// each scenario below is re-derived from its description in
/// docs/superpowers/reviews/2026-07-26-cold-review-round[4-6].md and
/// docs/superpowers/reviews/2026-07-27-cold-review-round[7-8].md.
/// CONTROL-PORTABLE: stable reducer API + observable asserts only (Task 10 drops
/// this file unchanged into control worktrees at 0ec11f8 / 6cb370a / fe843eb).
final class WatcherSegmentBatteryTests: XCTestCase {

    private struct ScriptedWatcherDriver {
        var reducer: WatcherReducer
        var emitted: [EmissionIntent] = []
        var logs: [(nanos: UInt64, line: String)] = []
        private var lastNowNanos: UInt64 = 0

        init(configuration: WatcherReducerConfiguration) {
            reducer = WatcherReducer(
                state: WatcherState(
                    generation: GenerationState(
                        id: FolderGeneration(rawValue: 1),
                        files: [:],
                        ordering: RevisionOrderingState(activeBlocker: nil)),
                    lastEmittedDigestByName: [:]),
                configuration: configuration)
        }

        mutating func observe(_ entries: [FileObservation], at nowNanos: UInt64) {
            lastNowNanos = nowNanos
            apply(reducer.reduce(.observe(ObservationBatch(
                generation: reducer.state.generation.id,
                entries: entries,
                nowNanos: nowNanos))))
        }

        /// Settles every outstanding intent in emission order, honoring the real
        /// driver's pre-yield check (`shouldExecuteEmission`), then records outcomes.
        mutating func settleAll(_ outcome: EmissionResult.Outcome = .yielded) {
            while !emitted.isEmpty {
                let intent = emitted.removeFirst()
                let effective: EmissionResult.Outcome =
                    reducer.shouldExecuteEmission(intent) ? outcome : .rejected
                apply(reducer.reduce(.emissionFinished(EmissionResult(
                    intent: intent, outcome: effective))))
            }
        }

        var abandonLogs: [(nanos: UInt64, line: String)] {
            logs.filter { $0.line.contains("abandoning") }
        }

        private mutating func apply(_ effects: [WatcherEffect]) {
            for effect in effects {
                switch effect {
                case .emit(let intent): emitted.append(intent)
                case .log(let line): logs.append((lastNowNanos, line))
                }
            }
        }
    }

    private func makeDriver() -> ScriptedWatcherDriver {
        ScriptedWatcherDriver(configuration: WatcherReducerConfiguration(
            digestPolicy: .mutableStackerOutput,
            filePrefix: "live_stack",
            quietPeriodNanos: 100_000_000,
            pollIntervalNanos: 1_000_000_000))
    }

    private func revisionName(_ revision: String) -> String { "live_stack_\(revision).fit" }

    private func makeIdentity(_ value: Int64) -> FileIdentity {
        FileIdentity(dev: value, ino: UInt64(value), size: Int(value) * 10,
                     mtimeSec: value, mtimeNsec: value)
    }

    private func digested(_ revision: String, _ digest: String, id: Int64) -> FileObservation {
        let identity = makeIdentity(id)
        return FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .digested(identity: identity, digest: digest, byteCount: identity.size))
    }

    private func invalid(_ revision: String) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .invalid)
    }

    private func absent(_ revision: String) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .absent)
    }

    private func iu(_ revision: String, id: Int64) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .identityUnchanged(identity: makeIdentity(id)))
    }

    private func ownSeconds(in line: String) -> Int? {
        Int(line.components(separatedBy: "blocked emissions for ").last?
            .components(separatedBy: "s ").first ?? "")
    }
}
```

Note `iu(_:id:)` is used only to keep **already-ready or settled** files present (Global Constraints: `.identityUnchanged` never advances an unready file). Files that must *become* ready are always driven with three `digested` sightings.

- [ ] **Step 2: Add the redemption family — d1, d2, d9**

```swift
// d1 — present-victim (running-segment) redemption. Provenance: round-8 C3
// ("running clocks never reset on owner emission"), spec §5.1 uniform redemption.
// Expected on scalar controls: RED on all three (write-off of the successor before
// its own budget, off inherited accrual).
func test_d1_ownerEmissionWhileVictimPresentGivesSuccessorFreshBudget() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Victim 3 becomes ready behind invalid 1 (three sightings; blocked throughout).
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
    // Owner 1 converges and emits at t=5s, victim PRESENT the whole time; a stalled
    // invalid 2 is present at the emission pass so the victim never becomes unblocked.
    d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 3 * sec)
    d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 4 * sec)
    d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 5 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
    d.settleAll(.yielded)

    // Successor 2 stalls; charging starts at t=6s. Fresh budget => first write-off
    // may fire no earlier than t=36s.
    for tick in 6...35 {
        d.observe([invalid("00002"), iu("00003", id: 3)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "successor written off at t=\(tick)s — inherited accrual (d1/C3); got \(d.logs)")
    }
    d.observe([invalid("00002"), iu("00003", id: 3)], at: 36 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1, "fresh budget exhausts exactly at 30s of own tenure")
    XCTAssertEqual(d.reducer.state.generation.files[revisionName("00002")], .writtenOff)
    d.settleAll(.yielded)
    XCTAssertTrue(d.emitted.isEmpty)
}

// d2 — paused-victim redemption. Provenance: round-7 R7-1 fix direction (paused
// charge must clear when its owner emits), spec §5.1 "d9's paused case".
// Expected on controls: RED on 6cb370a (structurally-dead clear), green elsewhere.
func test_d2_ownerEmissionDuringVictimAbsenceRedeemsPausedDebt() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
    // 20s of charge under owner 1, then the victim flickers absent while owner 1
    // converges and emits.
    d.observe([invalid("00001"), iu("00003", id: 3)], at: 20 * sec)
    d.observe([digested("00001", "done", id: 1), absent("00003")], at: 21 * sec)
    d.observe([digested("00001", "done", id: 1), absent("00003")], at: 22 * sec)
    d.observe([digested("00001", "done", id: 1), absent("00003")], at: 23 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
    d.settleAll(.yielded)

    // Victim returns behind fresh stalled 2 at t=25s: fresh budget, write-off ≥ 55s.
    for tick in 25...54 {
        d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "paused 20s not redeemed by owner emission (d2) — write-off at t=\(tick)s")
    }
    d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: 55 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1)
}

// d9 — emitted-owner pause + same-batch successor arrival. Provenance: round-7 R7-1
// repro and the round-8 control table row 1 (RED on 6cb370a: 9.0s; green on
// 0ec11f8/fe843eb: 31.0s). Spec §§4, 5.1.
func test_d9_freshSuccessorArrivingWithOwnersEmissionGetsFullBudget() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    d.observe([digested("00001", "c0", id: 1), digested("00003", "v", id: 3)], at: 0)
    d.observe([digested("00001", "c1", id: 1), digested("00003", "v", id: 3)], at: 1 * sec)
    d.observe([digested("00001", "c2", id: 1), digested("00003", "v", id: 3)], at: 2 * sec)
    // Victim 3 is ready and blocked behind churning 1; charge runs 2s..22s.
    d.observe([digested("00001", "final", id: 1), iu("00003", id: 3)], at: 22 * sec)
    // Emission pass: 1 becomes ready and emits; stalled 2 arrives in the SAME batch;
    // the victim flickers absent.
    d.observe([digested("00001", "final", id: 1), invalid("00002"), absent("00003")], at: 23 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
    d.settleAll(.yielded)

    // Victim returns at t=31s; successor 2's budget anchors at ITS first charge
    // (t=31s) => no write-off before t=61s.
    for tick in 31...60 {
        d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "d9 regression: successor written off at t=\(tick)s on inherited debt")
    }
    d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: 61 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1)
    XCTAssertEqual(d.reducer.state.generation.files[revisionName("00002")], .writtenOff)
}
```

- [ ] **Step 3: Add the carry family — d4 (with the driver-level log-honesty assertion) and C2**

```swift
// d4 — vanished owner's debt survives an unrelated successor's emission and is
// consumed with honest attribution. Provenance: round-8 M4 + round-7 fix direction;
// spec §§5.2, 5.4, 5.5. The log assertion here is the driver-level log-honesty
// gate: own time and predecessor debt are separate facts (M9).
func test_d4_vanishedOwnerDebtSurvivesUnrelatedEmissionAndIsConsumedHonestly() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Owner 1 (invalid) charges victim 5 from t=0; victim ready by t=2s.
    d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 0)
    d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 1 * sec)
    d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 2 * sec)
    // ... 20s of charge, then owner 1 VANISHES exactly as stalled 4 appears.
    d.observe([invalid("00001"), iu("00005", id: 5)], at: 19 * sec)
    d.observe([absent("00001"), invalid("00004"), iu("00005", id: 5)], at: 20 * sec)
    // Unrelated lower 2 converges and emits (23s..25s) while 4 still stalls.
    d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 23 * sec)
    d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 24 * sec)
    d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 25 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00002")])
    d.settleAll(.yielded)

    // Owner 1's 20s carried debt + owner 4's own tenure reach budget at t=33s:
    // charge under 4 ran 20..23 (3s) and resumes 26s.. => own = 3 + (t-26).
    // total = 20 + own >= 30 at t = 33s. If a resurrected removeAll had wiped the
    // carried debt at 2's emission, write-off would wait until ~t=56s.
    for tick in 26...32 {
        d.observe([invalid("00004"), iu("00005", id: 5)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty)
    }
    d.observe([invalid("00004"), iu("00005", id: 5)], at: 33 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1,
                   "carried predecessor debt must accelerate the stalled successor's write-off (d4)")
    let line = d.abandonLogs[0].line
    XCTAssertEqual(ownSeconds(in: line), 10,
                   "own-time clause reports owner 4's tenure only (3s+7s), never the 30s total")
    XCTAssertTrue(line.contains("consumed predecessor debt"), "log: \(line)")
    XCTAssertTrue(line.contains("1=20.0s"),
                  "the vanished owner's consumed 20s is named as a separate fact: \(line)")
}

// C2 — vanished-owner hijack with the lying 30s log. Provenance: round-8 C2
// (0.5s write-off, log claims "blocked emissions for 30s"). Spec §§5.4, 5.5.
// Expected on controls: RED on all three (early write-off with a lying own-time log).
func test_C2_acceleratedWriteOffAfterVanishedOwnerKeepsLogHonest() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
    d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
    for tick in 3...28 {
        d.observe([invalid("00001"), iu("00003", id: 3)], at: UInt64(tick) * sec)
    }
    // Owner 1 vanishes at 29s with 29s owed; brand-new stalled 2 takes over.
    d.observe([absent("00001"), invalid("00002"), iu("00003", id: 3)], at: 29 * sec)
    // total >= 30e9 at t=30s and owner 2's base grace (0.1s) expired => accelerated
    // write-off IS allowed — but only with honest attribution.
    d.observe([invalid("00002"), iu("00003", id: 3)], at: 30 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1)
    let line = d.abandonLogs[0].line
    let own = ownSeconds(in: line) ?? -1
    XCTAssertLessThanOrEqual(own, 2,
                             "C2's lying log: own-time clause must be ~1s, not the inherited 30s: \(line)")
    XCTAssertTrue(line.contains("consumed predecessor debt") && line.contains("1=29.0s"),
                  "predecessor debt appears as its own labeled fact: \(line)")
}
```

- [ ] **Step 4: Add the transient-occupant family — e1, e7**

```swift
// e1 — unrelated-lower emission must not clear a live stalled blocker's charge.
// Provenance: round-6 R6-1 (57s hold), round-8 R8-1 + control table (RED on
// 0ec11f8 and fe843eb; green on 6cb370a at 3.0s/30s). Spec §§5.1, M7.
func test_e1_transientLowerEmissionDoesNotClearLiveStalledBlockerCharge() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Stalled 5 charges victim 6 from t=0 (victim ready by 2s).
    d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 0)
    d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 1 * sec)
    d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 2 * sec)
    d.observe([invalid("00005"), iu("00006", id: 6)], at: 19 * sec)
    // Transient lower 3 passes through the blocker slot (20s..22s) and emits.
    d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 20 * sec)
    d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 21 * sec)
    d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 22 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00003")])
    d.settleAll(.yielded)

    // Owner 5's 20s survives; its own accrual resumes at 23s => write-off by t=33s
    // (20 + (33-23) = 30). A scalar broad clear restarts and holds until ~52s.
    for tick in 23...32 {
        d.observe([invalid("00005"), iu("00006", id: 6)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty)
    }
    d.observe([invalid("00005"), iu("00006", id: 6)], at: 33 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1,
                   "e1: the live blocker's charge survived the transient's emission — bounded hold")
    XCTAssertEqual(d.reducer.state.generation.files[revisionName("00005")], .writtenOff)
}

// e7 — repeated adversarial lower arrivals; the hold must not grow per arrival.
// Provenance: round-7 closed list (36.0s), round-8 R8-1 ("grows linearly with
// adversarial arrivals — unbounded pattern"); control table: RED on 0ec11f8 and
// fe843eb, green on 6cb370a. Spec §§4, 5.3.
func test_e7_adversarialLowerArrivalsDoNotGrowTheStalledBlockersHold() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 0)
    d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 1 * sec)
    d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 2 * sec)
    // Four adversarial cycles: lower k converges over 3 ticks and emits, each
    // pausing owner 8's accrual for its transient tenure + one barrier tick.
    var tick: UInt64 = 3
    for lower in ["00001", "00002", "00003", "00004"] {
        for _ in 0..<3 {
            d.observe([digested(lower, "low-\(lower)", id: Int64(lower)! ),
                       invalid("00008"), iu("00009", id: 9)], at: tick * sec)
            tick += 1
        }
        d.settleAll(.yielded)
    }
    // Owner 8 charged 0..3, then per cycle its segment pauses ~2 transient ticks +
    // 1 barrier tick; accrual = wall - 4*3 = wall - 12. Budget reached at wall 42s.
    while tick <= 41 {
        d.observe([invalid("00008"), iu("00009", id: 9)], at: tick * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "premature write-off at t=\(tick)s — transient inherited the charge")
        tick += 1
    }
    d.observe([invalid("00008"), iu("00009", id: 9)], at: 42 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1,
                   "e7: bounded at budget + per-cycle pause cost; scalar builds grow per arrival")
}
```

- [ ] **Step 5: Add the identity family — h3, h4, padding twins, c3**

```swift
// h3 — owner padding-renames during the victim's absence; its emission must still
// redeem. Provenance: round-8 R8-2 + control table (RED on all three: 9.0s).
// Spec §3.1 (RevisionKey normalization).
func test_h3_paddingRenameDuringAbsenceStillRedeemsOnEmission() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Owner "7" (unpadded) charges victim 10 for 10s; victim ready by 2s.
    // Victim revision 00010 sits ABOVE both the owner (7) and the fresh
    // stalled blocker (00009), so it stays genuinely blocked throughout.
    d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 0)
    d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 1 * sec)
    d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 2 * sec)
    d.observe([invalid("7"), iu("00010", id: 10)], at: 9 * sec)
    // Victim goes absent; the owner is renamed to "007" and converges (10s..12s).
    d.observe([digested("007", "done", id: 7), absent("00010")], at: 10 * sec)
    d.observe([digested("007", "done", id: 7), absent("00010")], at: 11 * sec)
    d.observe([digested("007", "done", id: 7), absent("00010")], at: 12 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("007")])
    d.settleAll(.yielded)

    // Fresh stalled 9 appears as the victim returns at 13s: RevisionKey("7") ==
    // RevisionKey("007") redeemed the paused 10s => no write-off before t=43s.
    for tick in 13...42 {
        d.observe([invalid("00009"), digested("00010", "v", id: 10)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "h3: stale unredeemed padding-variant debt shortened the fresh budget (t=\(tick)s)")
    }
    d.observe([invalid("00009"), digested("00010", "v", id: 10)], at: 43 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1)
}

// h4 — same-batch present handoff. Provenance: round-8 R8-3 + control table
// (RED on all three: 8.0s, no flicker needed). Spec §4 (pending-emission barrier).
func test_h4_sameBatchPresentHandoffDoesNotInheritRedeemedTime() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    d.observe([digested("00001", "c0", id: 1), digested("00003", "v", id: 3)], at: 0)
    d.observe([digested("00001", "c1", id: 1), digested("00003", "v", id: 3)], at: 1 * sec)
    d.observe([digested("00001", "c2", id: 1), digested("00003", "v", id: 3)], at: 2 * sec)
    d.observe([digested("00001", "final", id: 1), iu("00003", id: 3)], at: 24 * sec)
    // Handoff batch at 25s: 1 ready+emits, stalled 2 arrives, victim PRESENT.
    d.observe([digested("00001", "final", id: 1), invalid("00002"), iu("00003", id: 3)], at: 25 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
    d.settleAll(.yielded)

    // Successor 2 charges from 26s => no write-off before t=56s.
    for tick in 26...55 {
        d.observe([invalid("00002"), iu("00003", id: 3)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "h4: same-batch handoff inherited the old owner's 25s (t=\(tick)s)")
    }
    d.observe([invalid("00002"), iu("00003", id: 3)], at: 56 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1)
}

// c3 + padding twins — victim identity churn between padding variants stays
// bounded, each twin holding its own filename-keyed ledger. Provenance: rounds 4-6
// ("identity churn r_10<->r_010 ... bounded (62.0s)"), round-6 "padding twins get
// their own budgets". Spec §§3.1, 5.2.
func test_c3_victimPaddingChurnBehindStalledBlockerStaysBounded() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Stalled 9 blocks; the victim alternates names 10 / 010 every tick, so each
    // twin accrues ~half the wall time. Either ledger reaches 30s by wall ~60s;
    // assert write-off of 9 by the round-6 bound of 62s.
    var tick: UInt64 = 0
    while tick <= 62 {
        let twin = tick.isMultiple(of: 2) ? "10" : "010"
        let gone  = tick.isMultiple(of: 2) ? "010" : "10"
        d.observe([invalid("00009"),
                   digested(twin, "v", id: 10),
                   absent(gone)], at: tick * sec)
        if !d.abandonLogs.isEmpty { break }
        tick += 1
    }
    XCTAssertFalse(d.abandonLogs.isEmpty,
                   "c3: alternating padding-twin victims must not starve forever")
    XCTAssertLessThanOrEqual(d.abandonLogs[0].nanos, 62 * sec,
                             "bounded at ~2x budget under 50% alternation (round-6: 62.0s)")
    XCTAssertEqual(d.reducer.state.generation.files[revisionName("00009")], .writtenOff)
}
```

- [ ] **Step 6: Add the lifecycle family — S5, b1, e9/barrier-cost**

```swift
// S5 — victim flicker (absent 1 scan in 5) must not starve. Provenance: round-1 S5
// via round-4 W4-2 ("never emitted in 800s"), round-5 "emits at 33-40s". Spec M1/M3.
func test_S5_victimFlickerPausesButStillReachesWriteOffWithinCeiling() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    var tick: UInt64 = 0
    while tick <= 40 {
        let victimObservation = tick % 5 == 4
            ? absent("00002")
            : digested("00002", "v", id: 2)
        d.observe([invalid("00001"), victimObservation], at: tick * sec)
        if !d.abandonLogs.isEmpty { break }
        tick += 1
    }
    XCTAssertFalse(d.abandonLogs.isEmpty, "S5: flickering victim starved (no write-off by 40s)")
    XCTAssertLessThanOrEqual(d.abandonLogs[0].nanos, 40 * sec,
                             "cumulative present-blocked time bounds the hold (round-5: 33-40s)")
    // The victim emits once the corpse is gone and its digest gate re-earns.
    let t = d.abandonLogs[0].nanos / sec
    d.observe([digested("00002", "v", id: 2)], at: (t + 1) * sec)
    d.observe([digested("00002", "v", id: 2)], at: (t + 2) * sec)
    d.observe([digested("00002", "v", id: 2)], at: (t + 3) * sec)
    XCTAssertTrue(d.emitted.map(\.candidate.name).contains(revisionName("00002")))
}

// b1 / W4-2a — a long unblocked stretch precedes a fresh blocker: no stale debt
// may shorten the fresh budget. Provenance: round-4 W4-2a; closed since round 5,
// expected GREEN on all controls. Spec §5.2.
func test_b1_freshBlockerAfterLongUnblockedStretchGetsFullBudget() {
    var d = makeDriver()
    let sec: UInt64 = 1_000_000_000

    // Early episode: stalled 1 charges victim 2 for 10s, then 1 vanishes and the
    // victim emits (present and unblocked).
    d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 0)
    d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 1 * sec)
    d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 2 * sec)
    d.observe([invalid("00001"), iu("00002", id: 2)], at: 10 * sec)
    d.observe([absent("00001"), iu("00002", id: 2)], at: 11 * sec)
    XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00002")])
    d.settleAll(.yielded)

    // 90 quiet seconds later a fresh stalled 3 blocks new victim 4: full budget.
    d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 100 * sec)
    d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 101 * sec)
    d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 102 * sec)
    for tick in 103...129 {
        d.observe([invalid("00003"), iu("00004", id: 4)], at: UInt64(tick) * sec)
        XCTAssertTrue(d.abandonLogs.isEmpty,
                      "b1: stale pre-stretch debt shortened the fresh budget (t=\(tick)s)")
    }
    d.observe([invalid("00003"), iu("00004", id: 4)], at: 130 * sec)
    XCTAssertEqual(d.abandonLogs.count, 1, "write-off exactly one budget after the fresh first charge")
}

// e9 + barrier cost — a stream of resolving lower emissions delays the stalled
// blocker's write-off only by the per-cycle pause cost; the bound is linear with
// NO compounding reset, identical shape at higher cycle counts. Provenance:
// round-7 e9 ("bounded at 48.0s, identical at 20/60/100 cycles"), spec §§4, 5.3.
func test_e9_writeOffBoundGrowsOnlyByPerCyclePauseCostNeverResets() {
    let sec: UInt64 = 1_000_000_000
    for cycles in [2, 5] {
        var d = makeDriver()
        d.observe([invalid("00010"), digested("00020", "v", id: 20)], at: 0)
        d.observe([invalid("00010"), digested("00020", "v", id: 20)], at: 1 * sec)
        d.observe([invalid("00010"), digested("00020", "v", id: 20)], at: 2 * sec)
        var tick: UInt64 = 3
        for lower in 1...cycles {
            let revision = String(format: "%05d", lower)
            for _ in 0..<3 {
                d.observe([digested(revision, "low-\(lower)", id: Int64(lower)),
                           invalid("00010"), iu("00020", id: 20)], at: tick * sec)
                tick += 1
            }
            d.settleAll(.yielded)
        }
        // Owner 10's accrual = wall - 3*cycles; budget reached at 30 + 3*cycles.
        let bound = UInt64(30 + 3 * cycles)
        while tick < bound {
            d.observe([invalid("00010"), iu("00020", id: 20)], at: tick * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "cycles=\(cycles): premature write-off at t=\(tick)s")
            tick += 1
        }
        d.observe([invalid("00010"), iu("00020", id: 20)], at: bound * sec)
        XCTAssertEqual(d.abandonLogs.count, 1,
                       "cycles=\(cycles): bound is budget + per-cycle cost — no compounding, no reset")
    }
}
```

- [ ] **Step 7: Run the battery and record**

Run: `swift test --filter WatcherSegmentBatteryTests`

Expected: PASS (all 13). If any timing assert misses by exactly one poll tick, re-derive the arithmetic in the test comment before touching production code — the comments carry the full accrual computation for exactly this purpose. Record in the reconciliation doc any expectation that had to change, with its spec clause.

- [ ] **Step 8: Commit the battery**

```bash
git add Tests/LiveAstroCoreTests/WatcherSegmentBatteryTests.swift docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md
git commit -m "test: regenerate watcher battery as in-repo driver-faithful tests"
```

---

### Task 10: Control-Snapshot Counterfactuals

**Files:**
- Modify: `docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md` (record the observed matrix)

**Interfaces:**
- Consumes: the control-portable `WatcherSegmentBatteryTests.swift` (Task 9); the three control commits, all present in history: `0ec11f8` (round-6 code), `6cb370a` (round-7 code), `fe843eb` (round-8 code).
- Produces: the red/green counterfactual half of the acceptance gate (spec §7.3) — proof the battery discriminates, not just confirms.

The mechanism: a `git worktree` at each control commit **is** the file-for-file control build (the whole scalar-era `WatcherFileState.swift` + driver + their own then-green tests). The portable battery file is copied in unchanged; it compiles because it touches only the API surface verified stable across all three shas (`git show <sha>:Sources/LiveAstroCore/Watch/WatcherFileState.swift` — `case replaceGeneration`, `EmissionResult.Outcome`, `FileObservation.observedAtNanos` all present; see File Structure).

- [ ] **Step 1: Sanity-check the control commits and API surface**

```bash
for sha in 0ec11f8 6cb370a fe843eb; do
  git show $sha:Sources/LiveAstroCore/Watch/WatcherFileState.swift \
    | grep -c "case replaceGeneration\|case yielded\|observedAtNanos"
done
```

Expected: `4` printed three times (the `observedAtNanos` pattern matches two lines — the declaration and its use in `reduce`). Any other output: stop — the portability assumption broke; fix the battery's helper layer (never its assertions) before proceeding.

- [ ] **Step 2: Run the battery on each control snapshot**

```bash
for sha in 0ec11f8 6cb370a fe843eb; do
  git worktree add "../liveastro-ctl-$sha" "$sha"
  cp Tests/LiveAstroCoreTests/WatcherSegmentBatteryTests.swift \
     "../liveastro-ctl-$sha/Tests/LiveAstroCoreTests/"
  (cd "../liveastro-ctl-$sha" && swift test --filter WatcherSegmentBatteryTests 2>&1 \
     | tee "/tmp/watcher-ctl-$sha.log" | tail -20)
done
```

- [ ] **Step 3: Verify the binding expected-red matrix**

Check each `/tmp/watcher-ctl-<sha>.log` against the round-8 control table (`docs/superpowers/reviews/2026-07-27-cold-review-round8.md`, Section 3). **Binding** rows — any deviation here is a stop-the-line finding, not a note:

| Battery test | `0ec11f8` (r6) | `6cb370a` (r7) | `fe843eb` (r8) |
|---|---|---|---|
| `test_d9_freshSuccessorArrivingWithOwnersEmissionGetsFullBudget` | green | **RED** | green |
| `test_e1_transientLowerEmissionDoesNotClearLiveStalledBlockerCharge` | **RED** | green | **RED** |
| `test_e7_adversarialLowerArrivalsDoNotGrowTheStalledBlockersHold` | **RED** | green | **RED** |
| `test_h3_paddingRenameDuringAbsenceStillRedeemsOnEmission` | **RED** | **RED** | **RED** |
| `test_h4_sameBatchPresentHandoffDoesNotInheritRedeemedTime` | **RED** | **RED** | **RED** |

Informative rows (record observed result + one-line explanation; the round-8 table does not constrain them): `test_d1_*` and `test_C2_*` are expected red on all three (C3/C2 classes); `test_d2_*` red on `6cb370a`; `test_b1_*` green on all three (closed since round 5); `test_c3_*`/`test_S5_*`/`test_e9_*`/`test_d4_*` per observation.

- [ ] **Step 4: Record the matrix and clean up**

Fill the "Control-snapshot matrix" section of the reconciliation doc with the full observed grid (every battery test × every sha, pass/fail + the failing assert's message for reds). Then:

```bash
for sha in 0ec11f8 6cb370a fe843eb; do
  git worktree remove --force "../liveastro-ctl-$sha"
done
git worktree prune
```

- [ ] **Step 5: Commit the recorded counterfactuals**

```bash
git add docs/superpowers/reviews/2026-07-27-watcher-clock-battery-reconciliation.md
git commit -m "test: record watcher control-snapshot counterfactuals"
```

---

### Task 11: Full Acceptance Gates

**Files:** none modified (verification only; reconciliation doc updated if any gate discovers drift).

- [ ] **Step 1: Named H1/H2 hygiene re-run (spec §3.2: "no new hygiene rule … beyond re-running the existing H1/H2 map-bound checks")**

Run: `swift test --filter StackFileWatcherTests`

Expected: PASS — this is the real-driver suite carrying the tombstone lifecycle, map-bound/quiescence, multi-scan absence (`testMutablePolicy_multiScanVictimAbsencePausesClockThroughDriverTombstone`), lone-blocker fresh-budget, ceiling, and write-off log-parsing tests. It is deliberately unmodified (see File Structure); any red here means the segment model broke a driver-level contract — fix production code, never these tests, and record the investigation in the reconciliation doc.

- [ ] **Step 2: Watcher suites**

Run: `swift test --filter WatcherReducerTests`

Expected: PASS.

Run: `swift test --filter WatcherReducerPropertyTests`

Expected: PASS (includes the ≥3000-run N1 sweep).

Run: `swift test --filter WatcherSegmentBatteryTests`

Expected: PASS.

- [ ] **Step 3: Full gates**

Run: `swift test`

Expected: PASS.

Run: `swift build -c release`

Expected: PASS.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 4: Grep the corpse**

Run: `rg -n "VictimBlockingClock|ChargingBlocker|victimClocks|deadlineNanos|folderGenerationChanged" Sources Tests`

Expected: zero hits in `Sources/` and `Tests/` (docs may still mention them historically).

- [ ] **Step 5: Final commit and hand off — do not merge**

```bash
git add -A
git commit -m "test: prove watcher clock segment model" --allow-empty
git log --oneline main..HEAD
```

The branch now waits for the **external round-9 verification** (independent re-run of the battery, the control counterfactuals, and the sweep). Merging before that verification returns green violates the plan's branch discipline.

---

## Final Review Checklist

- [ ] Work happened entirely on `feature/watcher-segment-clocks`; `main` untouched; merge deferred to round-9 external verification.
- [ ] Every transition in `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md` maps to at least one committed test.
- [ ] `ChargingBlocker`, `VictimBlockingClock`, `victimClocks`, and `deadlineNanos` are gone from production watcher code and tests (Task 11 Step 4 grep).
- [ ] `reconcileActiveBlocker` contains zero `removeAll()` calls; ledgers are touched only by owner-keyed redemption, the victim's own emission, discharge, mark drops, write-off consumption, and generation swap.
- [ ] The d4 test (`testSegmentModel_d4VanishedOwnerDebtSurvivesUnrelatedSuccessorEmission` + battery `test_d4_*`) would catch any resurrected broad clear.
- [ ] `lastEmittedDigestByName` remains per filename and survives folder-generation changes.
- [ ] `RevisionKey` is the only owner key used for segment redemption and write-off consumption; no `ExpressibleByStringLiteral`; all ordering via `NumberedRevisionOrder`.
- [ ] The pending-emission barrier blocks successor charging, segment consumption, and write-off; it pauses rather than extends; it never skips the end-of-pass settlement; it does not block file-state updates or intent recording.
- [ ] The discharge predicate `isPresentAndUnblocked(name:classifiedByName:)` uses the classified batch + file states + numeric order — never `activeBlocker`, `pendingEmissionOwners`, or charging state — and treats invalid-with-no-files-entry lowers as blockers.
- [ ] `WriteOffDecision.consumedSegments` holds predecessor debt only, zero-amount entries excluded, truncating consumption; write-off logs separate own wait from predecessor debt while keeping the scalar-era leading clause byte-compatible.
- [ ] Grace/budget/ceiling read only from `blockingBudgetNanos`/`blockingGraceNanos`/`blockingCeilingNanos`; convergence renewal wired to the `isConverging` signal from `reduceStableDigest`/`reduceSettledReplacementDigest`; churn does not renew.
- [ ] `pendingEmissionOwners` and `ownerGraceUntil` have cleanup transitions on settlement, redemption, write-off, end-of-pass pruning, and generation swap — with tests pinning generation-swap and quiescence emptiness.
- [ ] The regenerated battery covers d1, d2, d4, d9, e1, e7, e9, h3, h4, b1, c3, S5, C2, padding twins, and the barrier-cost bound — each citing its probe id and review doc; driver-level log honesty asserted in `test_d4_*`/`test_C2_*`.
- [ ] Control counterfactuals recorded: d9 red on `6cb370a`; e1/e7 red on `0ec11f8` and `fe843eb`; h3/h4 red on all three.
- [ ] The ≥3000-run driver-faithful sweep is green with the two-condition N1 (no write-off before first-charge + budget UNLESS explicit predecessor debt consumed AND the owner's own grace expired), observed via `writeOffDecisionHookForTesting`.
- [ ] `swift test`, `swift build -c release`, and `git diff --check` pass; `StackFileWatcherTests` (H1/H2) passes unmodified.
