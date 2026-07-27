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
struct RevisionKey: Hashable, Comparable {
    let normalizedDigits: String
}
```

The existing anchored revision parser remains the single source of truth. Raw
names may still be kept for logs and emission intents, but segment ownership,
redemption, and padding-tie comparisons use `RevisionKey`. This closes the
padding-rename-during-absence family: `r_1.fit`, `r_01.fit`, and equivalent
padding variants redeem the same owner.

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
    let firstObservedNanos: UInt64
    var victims: Set<String>
}
```

Deadlines are derived from ledgers when deciding write-off, not stored as the
episode's inherited minimum. This removes the "oldest-clock-governs successor"
bug class.

---

## 4. Reducer ordering

Each observation batch is applied in this order:

1. **Classify the complete batch.** Build the fd-pinned, generation-scoped
   observation snapshot exactly as today.
2. **Redeem resolved owners.** For every numbered emission finishing in this
   reduce pass, redeem all segments whose `owner == emitted RevisionKey`,
   regardless of whether the victim is currently present or absent.
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

The load-bearing ordering is redemption before successor charging. The h4
same-batch present-handoff case then falls out without a special case: segments
charged to the old owner are redeemed before the successor episode begins
charging, so the successor starts from a clean attribution base.

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

### 5.3 Starvation is bounded over unredeemed wait

Under uniform redemption, a victim can wait longer than one budget across a
chain of sequentially emitting blockers. Example: B1 stalls for 29s, emits,
then B2 stalls for another 29s. That is correct, not a hole: emission is stream
progress, and M1's starvation bound applies to unredeemed wait, not total wall
time across resolving owners.

The contrast case is a vanished blocker. Since it did not emit, its segment is
not redeemed and continues to count as unresolved wait.

### 5.4 Write-off attribution and logging

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

### 5.5 Multi-victim policy

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
| M1 starvation bound | Write-off checks total unredeemed victim ledger time, paused absence preserved by tombstones. |
| M2 attribution | Segments are keyed by owner; a blocker cannot be written off before its own charged interval plus allowed unresolved debt reaches budget. |
| M3 absence pauses | Victim ledger survives absence; `runningSinceNanos` is closed/paused, not aged or deleted. |
| M4 redemption vs carry | Emission redeems matching owner segments; vanished owners leave segments unredeemed. |
| M5 same-batch ordering | Batch reducer redeems emitted owners before deriving/charging successor episodes. |
| M6 identity | Segment owners are `RevisionKey`, normalized from numeric revision, not raw filename. |
| M7 transient occupancy | A transient blocker only accrues the interval it actually owns; its emission redeems only its segment. |
| M8 hygiene | Segments compact on redemption/write-off, bounded by active+tombstoned victims, wiped at generation swap. |
| M9 log honesty | `WriteOffDecision` carries attributed/consumed segment durations; logs derive from it. |
| M10 composition proof | Acceptance requires driver-faithful batteries and control snapshots, not reducer-only injected states. |

---

## 7. Acceptance gate

Implementation is not complete until all of these pass against the real driver
synthesis rule:

1. The accumulated `fw6-watch`, `fw7-watch`, and `fw8-watch` batteries.
2. All three control snapshots from rounds 6, 7, and 8, with the expected
   red/green counterfactuals preserved:
   - d9 red on round 7, green on segment model;
   - e1/e7 red on rounds 6 and 8, green on segment model;
   - h3/h4 red on all scalar-control builds, green on segment model.
3. The 3000-run sweep with timing-bound invariant N1: no blocker is written
   off before first charge plus budget, except where the decision explicitly
   consumes unredeemed predecessor debt.
4. Existing watcher/folder/fault battery.
5. Full `swift test`.
6. `swift build -c release`.
7. `git diff --check`.

Reducer-only tests are useful for red-first development, but they do not count
as acceptance evidence unless paired with driver-faithful composition tests.

---

## 8. Implementation-plan boundaries

The implementation plan should be small and staged:

1. Introduce `RevisionKey`, `AccrualSegment`, and `VictimWaitLedger` behind
   tests without changing scanner behavior.
2. Replace scalar `VictimBlockingClock` operations with ledger transitions:
   pause, resume/charge, redeem, consume/write-off, generation clear.
3. Reorder batch handling so redemption precedes successor charging.
4. Update write-off logging to derive from structured attribution.
5. Port/keep the existing tombstone and hygiene checks.
6. Run the full M10 acceptance gate before any merge or release claim.

No app-layer work should be mixed into this branch. If the implementation
reveals that the whole watcher file needs mechanical extraction for readability,
that extraction must be behavior-preserving and reviewed separately from the
segment semantics.
