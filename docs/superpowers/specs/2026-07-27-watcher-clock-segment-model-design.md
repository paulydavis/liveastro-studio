# Watcher Clock Segment Model — Design

**Trigger:** watcher verification round 8 found timing-bound regressions on
`fe843eb` after the round-7 adjudication rule had been recorded: if another
timing-bound violation appears, stop treating the issue as a missed guard and
redesign the clock-ownership model. That rule fired. The current scalar
`VictimBlockingClock` plus one `chargingBlocker` label cannot represent wait
earned under multiple owners, so every predicate variant has fixed one probe
and broken another.

**Scope:** replace the numbered-revision holdback clock model with per-owner
accrual segments. Preserve the existing watcher reducer architecture, file
state machine, stat/digest gates, folder-generation rules, identity/digest
verification, numeric ordering comparator, and tombstone synthesis. This is a
small ownership-model redesign inside the already-reduced watcher, not another
full watcher rewrite.

**Non-goals:** no changes to FITS completeness, digest policy, immutable vs.
mutable stacker-output behavior, relay logic, OBS, SessionPipeline, or app UI.
No release packaging work is part of this spec.

---

## 1. The defect class being closed

The mechanism exists for one purpose:

> Bound how long a ready victim waits behind unready blockers, while never
> charging a blocker for time it did not cause.

Rounds 6, 7, and 8 proved the current model cannot satisfy both halves with one
scalar clock:

- broad emission-time clearing fixed unrelated-lower-emission holds but erased
  wait still owed by live blockers;
- ordered clearing tried to distinguish those cases but became unreachable in
  real driver composition;
- equality clearing fixed the round-7 d9 counterexample but re-opened the
  unrelated-emission case and made vanished-owner charges immortal.

The control table in
`docs/superpowers/reviews/2026-07-27-cold-review-round8.md` is the acceptance
brief: d9, e1, e7, h3, and h4 cannot all pass under a single scalar owner label.
The redesigned type must make that ambiguity unrepresentable.

---

## 2. Options considered

### Option A — per-victim ledger of per-owner segments (approved)

Each victim owns a ledger of accrual segments keyed by the numeric revision of
the blocker that caused that interval. A blocker emission redeems only segments
charged to that owner. A blocker disappearance does not redeem; that unresolved
wait remains owed and can contribute to later write-off progress. Write-off
consumes the remaining unredeemed wait that justifies it.

This is the chosen design because it answers the two questions with two pieces
of state:

- how much unredeemed time has the victim waited?
- which owners caused each interval of that wait?

### Option B — one scalar clock per current blocker (rejected)

This is simpler, but it re-answers both questions with one scalar. That is the
exact failure mode eight waves just proved. It either loses cumulative
victim-wait under churn/flicker or misattributes predecessor wait to a successor
blocker.

### Option C — full ordering reducer rewrite (deferred)

A broader rewrite could make the whole ordering subsystem smaller again, but
the current reducer, file states, tombstones, generation handling, and numeric
comparator have held up outside the clock-ownership seam. The fix should be
narrow: replace the ambiguous clock representation, not the whole watcher.

---

## 3. State model

### 3.1 Normalized keys

All clock ownership is keyed by normalized numeric revision, not raw filename:

```swift
struct RevisionKey: Hashable {
    let normalizedDigits: String
}
```

The existing anchored revision parser remains the single source of truth. Raw
names may still be kept for logs and emission intents, but segment ownership,
redemption, and padding-tie comparisons use `RevisionKey`. This closes the
padding-rename-during-absence family: `r_1.fit`, `r_01.fit`, and equivalent
padding variants redeem the same owner.

`RevisionKey` must not sort lexicographically. Any ordering delegates to the
existing digit-string numeric comparator (`NumberedRevisionOrder.compare` /
`orderedBefore` semantics). A future `Comparable` conformance is allowed only
if it calls that comparator; `"10" < "9"` is a correctness bug.

Victims are still keyed by filename in the generation state, because a concrete
file path is what the watcher observes and emits. Segment owners are keyed by
revision because owner identity is the ordering fact being attributed.

### 3.2 Victim ledger

Replace the scalar `VictimBlockingClock` with a per-victim ledger:

```swift
struct VictimWaitLedger: Equatable {
    var segments: [RevisionKey: AccrualSegment]
    var pausedAtNanos: UInt64?
}

struct AccrualSegment: Equatable {
    let owner: RevisionKey
    var firstChargeNanos: UInt64
    var accruedNanos: UInt64
    var runningSinceNanos: UInt64?
}
```

`runningSinceNanos` is non-nil only while the victim is currently present and
blocked behind that owner. `pausedAtNanos` is a victim-level tombstone marker:
absence pauses all running accrual; it does not delete segments.

Ledger invariant: at most one segment is running for a victim at a time. When
the active owner changes, the reducer closes the previous running interval
before opening the next owner's interval. If the previous owner emitted, its
segment is redeemed; if it vanished, the closed segment remains as unresolved
predecessor debt.

The ledger is naturally bounded: per victim, segment count is at most the
distinct owners that blocked that victim within the current folder generation.
Segments are compacted by redemption and write-off, bounded by present plus
tombstoned files, and wiped by generation swap. No new hygiene rule is needed
beyond re-running the existing H1/H2 map-bound checks.

### 3.3 Active blocker

`BlockingEpisode` continues to describe the current head-of-line unready
revision and its active victims, but it no longer owns the only clock:

```swift
struct BlockingEpisode {
    let blockerName: String
    let owner: RevisionKey
    var victims: Set<String>
}
```

Deadlines are derived from ledgers when deciding write-off, not stored as the
episode's inherited minimum. This removes the "oldest-clock-governs successor"
bug class. The grace and ceiling anchor lives on each owner's `AccrualSegment`
(`firstChargeNanos`), not on `BlockingEpisode`; the episode is only the current
head-of-line role.

---

## 4. Reducer ordering

The reducer remains command-driven:

- `.observe(batch)` classifies observations and returns emission intents;
- the driver executes an intent only if `shouldExecuteEmission` still accepts
  it;
- `.emissionFinished(result)` settles the executed intent afterward.

Redemption fires only while reducing `.emissionFinished` for the current
generation, and only when `result.outcome == .yielded` and the candidate really
settles as `.emittedNow`. A rejected, skipped, stale-generation, or invalidated
intent does not redeem anything. This preserves the v3 settle-on-yield rule:
stream progress is observed only after the driver actually yields the frame.

Each observation batch is otherwise applied in this order:

1. **Classify the complete batch.** Build the fd-pinned, generation-scoped
   observation snapshot exactly as today.
2. **Apply already-settled redemptions.** All preceding yielded
   `.emissionFinished` commands have already redeemed their owners before this
   observe pass opens, extends, or consumes ledger segments. An `.observe`
   command must not redeem a candidate merely because it returns an emission
   intent.
3. **Apply terminal owner outcomes.** Written-off owners consume the segments
   used to justify their write-off. Vanished owners are not redeemed; their
   unredeemed segments remain owed.
4. **Derive the current head blocker and victims.** Use the existing numeric
   order and per-file states.
5. **Pause or charge ledgers.** Absent victims keep tombstone ledgers and do
   not age. Present victims behind the current blocker accrue time into that
   blocker's `RevisionKey` segment. A transient converging owner receives only
   the interval during which it truly holds the blocker slot.
6. **Decide write-off.** A blocker may be written off only when the victim
   ledger contains enough unredeemed attributed time to justify progress under
   the rules in §5. If that decision uses predecessor debt, the decision must
   identify the predecessor segments consumed; the current blocker is not
   described as having personally blocked for that predecessor time.
7. **Emit eligible candidates.** Emission intents remain generation-tagged and
   still pass through the existing consumer identity/digest verification.

The load-bearing ordering is redemption before successor charging in the
command stream. If an observe pass returns an old owner's emission intent and
also sees a possible successor blocker, the old owner is not redeemed on
intent; instead, any write-off decision that would depend on the old owner's
segments is deferred until after the corresponding yielded
`.emissionFinished`. The next observe pass then charges the successor against a
ledger where the yielded old owner has already been redeemed. This keeps h4's
same-batch present handoff from inheriting redeemed time without ever
pretending an unexecuted intent is stream progress.

Operationally, this is a **pending-emission barrier**: when an observe batch
returns one or more emission intents before the first unready candidate, the
reducer may record the emitted intents but must not open, extend, consume, or
write off successor-owner segments that depend on those pending owners in the
same `.observe` command. Successor charging resumes in the next observe pass
after the pending intents have either yielded (redeemed), rejected/skipped
(unredeemed), or gone stale. This is a narrow ordering rule for segment
attribution; it does not change the existing generation-tagged emission
protocol.

---

## 5. Semantics

### 5.1 Uniform redemption

Redemption applies uniformly to all segments charged to the emitting owner,
running or paused.

This is deliberate. Attribution does not depend on the victim's presence at
the instant an owner emits: the owner resolved, so the debt charged to it is
settled. Presence-conditional redemption would create another predicate seam.
The same transition closes both d9's paused case and h4's present case.

### 5.2 Vanished owners carry unresolved debt

An owner that disappears without emitting does not redeem its segments. That
wait remains unredeemed because no stream progress was observed for that owner.
Later blockers may inherit that unresolved debt as victim wait, but they may
not be charged as if they personally caused it.

This is the explicit d9-vs-d4 distinction:

- emitted owner: resolved progress, debt cleared;
- vanished owner: unresolved stall, debt still owed.

Unredeemed debt is not immortal across a broken blocking chain. It carries only
while the victim remains continuously blocked or absent. The reducer discharges
the victim's remaining unredeemed ledger after one full observe pass where that
victim is present and unblocked, because the victim had a real chance to emit
and the old stall no longer explains the current wait. The victim's own
successful emission also clears its ledger. This preserves the round-6 b1 /
W4-2a behavior: a victim unblocked for a long interval starts a later fresh
blocker with a fresh budget, not hours-stale debt.

For discharge, **unblocked** is a file-state/numeric-order fact: the victim is
present and there is no unready lower revision in the current generation. It is
derived from file states, not from `BlockingEpisode`, segment charging, or the
pending-emission barrier. A barrier-deferred successor may pause charging, but
it does not make a victim unblocked if an unready lower revision still exists.

### 5.3 Starvation is bounded over unredeemed wait

Under uniform redemption, a victim can wait longer than one budget across a
chain of sequentially emitting blockers. Example: B1 stalls for 29s, emits,
then B2 stalls for another 29s. That is correct, not a hole: emission is stream
progress, and M1's starvation bound applies to unredeemed wait, not total wall
time across resolving owners.

The contrast case is a vanished blocker. Since it did not emit, its segment is
not redeemed and continues to count as unresolved wait.

### 5.4 Convergence grace

The existing blocker budget and grace semantics remain part of the contract:

- budget = `max(30s, 10 × quietPeriod, 5 × pollInterval)`;
- grace renewal = one quiet period for a converging observation;
- hard ceiling = budget + `4 × quietPeriod`;
- churn that is not converging does not reset or extend the budget.

Predecessor debt may accelerate write-off of a stalled current blocker, but it
must not abandon a blocker that is actively converging under its own tenure.
Formally, write-off requires both:

1. the victim ledger has enough unredeemed wait to justify progress; and
2. the current owner is outside its own convergence grace window, anchored at
   that owner's first charge time and capped by that owner's ceiling.

Converging observations renew only the current owner's grace window. They do
not rewrite predecessor segments, and predecessor debt does not shorten a
fresh owner's grace. This is the R8-4/a6/g4 distinction: stale unresolved wait
can make a stalled successor progress quickly, but a genuinely converging
successor gets its grace window on its own clock.

### 5.5 Write-off attribution and logging

A write-off log reports the written-off blocker's own attributed time and any
explicit unresolved predecessor debt consumed for that decision as separate
facts. It must never report inherited episode age as though the blocker
personally blocked for that duration.

This means a successor can be the progress point that releases a victim after
unresolved predecessor debt has already consumed most of the budget, but the
state and log must say so. C2's failure was not "progress after predecessor
debt" by itself; it was permanent unclearable ownership collapsed into a fresh
blocker's personal clock, followed by a lying 30s log.

The implementation should return a structured write-off decision:

```swift
struct WriteOffDecision {
    let blocker: RevisionKey
    let blockerNameForLog: String
    let attributedNanos: UInt64
    let consumedSegments: [RevisionKey: UInt64]
}
```

The log is derived from this decision, not from an episode start timestamp.

### 5.6 Multi-victim policy

The current behavior writes off the head blocker when at least one held victim's
ledger reaches the write-off threshold. That behavior remains: one blocked
higher revision is enough to declare the head blocker lost. If implementation
uncovers a test asserting a stricter all-victims policy, treat that as a spec
conflict to bring back for review, not as an implicit design change. The
segment model changes attribution, not the product threshold.

---

## 6. Requirement-to-transition map

| Requirement | Design transition or invariant |
|---|---|
| M1 starvation bound | Write-off checks total unredeemed victim ledger time; resolved owners redeem, present-and-unblocked victims discharge stale ledgers, paused absence is preserved by tombstones. |
| M2 attribution | Segments are keyed by owner; a blocker cannot be written off before its own charged interval plus explicit unresolved predecessor debt reaches budget, and its own convergence grace has expired. |
| M3 absence pauses | Victim ledger survives absence; `runningSinceNanos` is closed/paused, not aged or deleted. |
| M4 redemption vs carry | Yielded `.emissionFinished` redeems matching owner segments; vanished owners leave segments unredeemed until redeemed, consumed, or discharged by an unblocked-present scan. |
| M5 same-batch ordering | Command stream applies yielded redemptions before the next observe pass charges/consumes those segments; observe-time intents do not redeem. |
| M6 identity | Segment owners are `RevisionKey`, normalized from numeric revision, not raw filename. |
| M7 transient occupancy | A transient blocker only accrues the interval it actually owns; yielded emission redeems only its segment; its convergence grace is anchored to its own first charge. |
| M8 hygiene | Segments compact on redemption/write-off, bounded by active+tombstoned victims, wiped at generation swap. |
| M9 log honesty | `WriteOffDecision` carries attributed/consumed segment durations; logs derive from it. |
| M10 composition proof | Acceptance requires reconciled driver-faithful batteries and control snapshots, not reducer-only injected states. |

---

## 7. Acceptance gate

Implementation is not complete until all of these pass against the real driver
synthesis rule:

1. **Battery reconciliation.** Before old batteries are binding, re-derive each
   `fw6-watch`, `fw7-watch`, and `fw8-watch` probe expectation from §§4-5.
   List every expectation that changes from scalar-era semantics with a
   one-line justification, then commit that reconciliation with the test
   update. The reconciled expectations are the gate; stale scalar-era asserts
   are not. Known likely reconciliations include vanished-owner debt carry,
   b1/W4-2a discharge after present-and-unblocked scans, and e9's bounded
   non-growing write-off expectation.
2. The reconciled accumulated `fw6-watch`, `fw7-watch`, and `fw8-watch`
   batteries.
3. All three control snapshots from rounds 6, 7, and 8, with the expected
   red/green counterfactuals preserved:
   - d9 red on round 7, green on segment model;
   - e1/e7 red on rounds 6 and 8, green on segment model;
   - h3/h4 red on all scalar-control builds, green on segment model.
4. The 3000-run sweep with timing-bound invariant N1: no blocker is written
   off before first charge plus budget, except where the decision explicitly
   consumes unredeemed predecessor debt and the current owner's own convergence
   grace has expired.
5. Existing watcher/folder/fault battery.
6. Full `swift test`.
7. `swift build -c release`.
8. `git diff --check`.

Reducer-only tests are useful for red-first development, but they do not count
as acceptance evidence unless paired with driver-faithful composition tests.

---

## 8. Implementation-plan boundaries

The implementation plan should be small and staged:

1. Introduce `RevisionKey`, `AccrualSegment`, and `VictimWaitLedger` behind
   tests without changing scanner behavior.
2. Replace scalar `VictimBlockingClock` operations with ledger transitions:
   pause, resume/charge, redeem, consume/write-off, generation clear.
3. Preserve the command protocol: redeem only on yielded `.emissionFinished`;
   add the pending-emission barrier so successor segment charging/consumption
   waits for prior intents to settle.
4. Add debt discharge after one full present-and-unblocked observe pass and
   after the victim's own successful emission.
5. Preserve convergence grace on the current owner's own segment, independent
   of predecessor debt.
6. Update write-off logging to derive from structured attribution.
7. Reconcile scalar-era battery expectations against this spec, then port/keep
   the existing tombstone and hygiene checks.
8. Run the full M10 acceptance gate before any merge or release claim.

No app-layer work should be mixed into this branch. If the implementation
reveals that the whole watcher file needs mechanical extraction for readability,
that extraction must be behavior-preserving and reviewed separately from the
segment semantics.
