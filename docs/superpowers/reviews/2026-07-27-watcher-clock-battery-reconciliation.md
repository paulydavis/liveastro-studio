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

## Plan deviations during execution

- **Task 6 red-step mispredicted the exit branch.** The single-file b1 batch reaches
  the lone-blocker branch (the unready victim itself is selected as blocker with zero
  victims), whose interim `retainVictimLedgers` else-arm deletes the ledger;
  present-unblocked Nil-asserts therefore cannot be red on the interim shape (they pass
  accidentally, before the discharge scan exists). True red supplied by the all-ready
  absent-victim pause probe
  (`testSegmentModelAllReadyPassPausesAbsentVictimLedgerInsteadOfDeleting`: interim
  all-ready `removeAll()` deletes a charged absent victim's ledger → red; end-of-pass
  settlement pauses it → green). The original three Step-1/2 tests are retained as
  final-behavior pins, not red-first evidence (pre-Step-4 observations: b1 passed via
  the interim lone-blocker deletion; invalid-lower passed via the charging path
  retaining the ledger; barrier passed via the explicit barrier pause).

- **Task 9 regeneration: no expectation changed.** Before running, every accrual
  comment in `WatcherSegmentBatteryTests.swift` was recomputed independently against
  the implemented digest-gate and ledger semantics (three-sighting readiness with
  `firstObservedNanos` at sighting 2; `startOrContinue` charging; barrier pause;
  end-of-pass discharge/pause; write-off = unredeemed total ≥ budget with owner grace
  expired). Recomputed write-off instants — d1: 36s, d2: 55s, d9: 61s, d4: 33s
  (own 10s + carried 1=20.0s), C2: 30s (own 1s + carried 1=29.0s), e1: 33s, e7: 42s,
  h3: 43s, h4: 56s, c3: 60s (≤ 62s bound), S5: 37s (≤ 40s bound), b1: 130s,
  e9: 30+3·cycles — all matched the plan asserts exactly; 13/13 passed on the first
  run with zero edits to expectations or production code.
- **Absent-observation fidelity note (Task 9).** The `ScriptedWatcherDriver` passes
  scripted batches through verbatim (the plan's control-portable harness); it does not
  re-implement the real watcher's absent synthesis (`files` ∪ ledger-tombstone keys).
  Fidelity was checked test-by-test instead: every behavior-relevant synthesis site
  (c3's vanished padding twin, d2/d9/h3 victim flicker, d4/C2 vanished owners) carries
  an explicit `.absent` entry, and every omitted tracked name is a provable classify
  no-op (settled → `withReplacement(nil)`; written-off → ignored; invalid-only owners
  never enter `files` or ledger keys), so the scripted batches are observationally
  identical to synthesized ones.

## Control-snapshot matrix (filled in by Task 10)

Binding rows (round-8 control table): d9 red on `6cb370a` only; e1/e7 red on
`0ec11f8` and `fe843eb`; h3/h4 red on all three. All other probes: record the
observed result per snapshot with a one-line explanation (informative, not binding).

### Run record (Task 10, 2026-07-30)

`WatcherSegmentBatteryTests.swift` copied byte-identical from `458ba11` (where it
is 13/13 green) into a fresh `git worktree` at each control sha; run with
`swift test --filter WatcherSegmentBatteryTests`, one worktree at a time. The
battery compiled cleanly at all three shas (Step-1 API precheck printed `4`
three times as expected). All 13 tests executed at every sha — no skips, no
crashes.

### Observed matrix (13 tests × 3 shas)

| Battery test | `0ec11f8` (r6) | `6cb370a` (r7) | `fe843eb` (r8) |
|---|---|---|---|
| `test_d1_ownerEmissionWhileVictimPresentGivesSuccessorFreshBudget` | FAIL | FAIL | FAIL |
| `test_d2_ownerEmissionDuringVictimAbsenceRedeemsPausedDebt` | pass | pass | pass |
| `test_d9_freshSuccessorArrivingWithOwnersEmissionGetsFullBudget` | pass | FAIL | pass |
| `test_d4_vanishedOwnerDebtSurvivesUnrelatedEmissionAndIsConsumedHonestly` | FAIL | FAIL | FAIL |
| `test_C2_acceleratedWriteOffAfterVanishedOwnerKeepsLogHonest` | FAIL | FAIL | FAIL |
| `test_e1_transientLowerEmissionDoesNotClearLiveStalledBlockerCharge` | FAIL | FAIL | FAIL |
| `test_e7_adversarialLowerArrivalsDoNotGrowTheStalledBlockersHold` | FAIL | FAIL | FAIL |
| `test_h3_paddingRenameDuringAbsenceStillRedeemsOnEmission` | FAIL (t=30) | FAIL (t=30) | FAIL (t=30) | *(after the 2026-07-31 rework — see triage record below; the original regeneration was pass/pass/pass)* |
| `test_h4_sameBatchPresentHandoffDoesNotInheritRedeemedTime` | FAIL | FAIL | FAIL |
| `test_c3_victimPaddingChurnBehindStalledBlockerStaysBounded` | pass | pass | pass |
| `test_S5_victimFlickerPausesButStillReachesWriteOffWithinCeiling` | pass | pass | pass |
| `test_b1_freshBlockerAfterLongUnblockedStretchGetsFullBudget` | pass | pass | pass |
| `test_e9_writeOffBoundGrowsOnlyByPerCyclePauseCostNeverResets` | FAIL | FAIL | FAIL |

Failing-assert messages for red cells (first failure per test; identical across
shas unless noted):

- d9 @ `6cb370a` (line 203): "d9 regression: successor written off at t=38s on
  inherited debt" — the round-7 structurally-dead guard, as the round-8 table
  describes.
- d1 (line 142): "successor written off at t=30s — inherited accrual (d1/C3)";
  write-off log shows the full inherited 30s.
- d4 (lines 241/247/249/250): `XCTAssertTrue failed` (no message) — vanished-owner
  carry and truncating consumption asserts, unrepresentable in the scalar model.
- C2 (log-honesty assert): `("30") is greater than ("2")` — the write-off log
  claims the inherited 30s as the fresh blocker's own time.
- e1 (line 306): `XCTAssertTrue failed` (no message) — stalled blocker's charge
  cleared/hijacked by the transient lower emission.
- e7: "premature write-off at t=30s — transient inherited the charge".
- h4 (line 401): "h4: same-batch handoff inherited the old owner's 25s (t=30s)".
- e9: "cycles=2: premature write-off at t=30s".

### Binding-row verdicts

| Binding row | Expected (r6/r7/r8) | Observed | Verdict |
|---|---|---|---|
| d9 | green / **RED** / green | pass / FAIL / pass | **MATCH** |
| e1 | **RED** / green / **RED** | FAIL / FAIL / FAIL | **DEVIATION** (`6cb370a` expected green, observed red) |
| e7 | **RED** / green / **RED** | FAIL / FAIL / FAIL | **DEVIATION** (`6cb370a` expected green, observed red) |
| h3 | **RED** / **RED** / **RED** | pass / pass / pass | **DEVIATION** (green on all three; expected red on all three) |
| h4 | **RED** / **RED** / **RED** | FAIL / FAIL / FAIL | **MATCH** |

**STOP-THE-LINE:** three binding rows deviate from the round-8 control table
(`2026-07-27-cold-review-round8.md` §3, verified identical to the plan's
transcription):

1. **h3 is green on all three control snapshots** where the round-8 table
   records `9.0s ✗` on all three. The regenerated h3 test does not discriminate
   the padding-rename-during-absence redemption defect on any scalar-era
   snapshot. Recorded as observed; per the plan's stop-the-line rule this is
   reported for controller triage of the battery's helper/choreography layer
   (never its assertions), not rationalized here.
2. **e1 is red on `6cb370a`** where the table records `3.0s/30s ✓` (green).
3. **e7 is red on `6cb370a`** (message: "premature write-off at t=30s —
   transient inherited the charge") where the table records `36.0s ✓` (green).

No conclusion is drawn here about whether the deviation lies in the regenerated
probes' choreography or in the round-8 table's characterization of the round-7
snapshot; that determination belongs to the triage that resolves this finding.
The counterfactual half of the acceptance gate is **not satisfied** until the
binding matrix is reconciled.

### Informative rows (observed, one-line explanations)

- **d1** red ×3 — expected (C3/C2 class): successor inherits the victim's
  accrual and is written off at t=30s of zero own tenure on every scalar
  snapshot.
- **C2** red ×3 — expected: the lying write-off log reports inherited time as
  the fresh blocker's own on every scalar snapshot.
- **d2** green ×3 — anticipated red on `6cb370a`; observed green: the battery's
  d2 choreography does not reach the round-7 paused-debt defect on control code
  (flagged to triage alongside the h3 finding, same absence/redemption family).
- **b1** green ×3 — expected: fresh-blocker-after-quiescence closed since
  round 5.
- **c3** green ×3 — the scalar model already bounds victim padding churn behind
  a stalled blocker (≤62s bound holds).
- **S5** green ×3 — flicker pause + ceiling behavior already satisfied by the
  scalar pause machinery.
- **e9** red ×3 — scalar snapshots write off prematurely at t=30s from cycle 2
  (inherited accrual defeats the per-cycle bound the segment model pins).
- **d4** red ×3 — vanished-owner debt carry with honest truncating consumption
  is the segment model's headline capability; no scalar snapshot has it.


### Triage record (2026-07-31) — deviations resolved; binding matrix amended

The 2026-07-30 run deviated from the round-8 binding table on three rows. Triage
outcome (controller-verified, per-sha mechanism evidence):

**h3 — battery fault, fixed (choreography only; assertions untouched).** The
regenerated h3 lost two discriminative ingredients of the historical R8-2 shape:
the fresh blocker must arrive in the SAME batch as the renamed owner's emission
(a later arrival lands on scalar dissolution clears), and the victim must STAY
PRESENT (an absent victim dissolves the episode, and round-6's over-broad
ordering clear then wipes the clock — an accidental green, because r6's defect
was OVER-clearing, which the h3 asserts cannot catch). Reworked h3 (victim
`00010` present throughout; `00009` arrives in the t=12 emission batch;
segment-model write-off assert unchanged at t=43): **green on the segment
model, RED at t=30 on all three controls.** Red mechanisms per sha: r6 —
episode alive at settlement, dissolution clear never runs, stale 12s retained;
r7 — running clocks carry a nil charge, the paused-only equality clear skips
them (see below); r8 — charge re-stamped to the transient episode blocker,
equality defeated. Binding row restored: RED / RED / RED.

**e1/e7 — binding cells amended for `6cb370a`: green → RED (justified).** The
round-8 table's `6cb370a` green cells encoded the ROUND-7-ERA probes, which used
paused-clock shapes tuned to r7's equality clear. The regenerated probes use
present (running-clock) victims — and on `6cb370a`,
`clearPausedVictimClocksResolvedByEmission` (line 421) begins
`guard let chargingBlocker = ...victimClocks[name]?.chargingBlocker` where the
charge is stamped ONLY at pause time: a running clock has a nil charge and is
skipped by every emission — never redeemed. That is round-8 finding C3
("running clocks never reset on owner emission") reached through the running
branch: a genuine scalar defect, line-confirmed. Observed failures: e1 premature
write-off (foreign accrual), e7 "premature write-off at t=30s — transient
inherited the charge". Discrimination is STRENGTHENED (red on an additional
defective build); the essential cells — red on the defect-bearing `0ec11f8`
and `fe843eb`, green on the segment model — are unchanged. Amended binding
matrix for e1/e7: RED / RED / RED.

**Amended binding matrix (final):** d9 green/RED/green (unchanged, matched);
h4 RED/RED/RED (unchanged, matched); h3 RED/RED/RED (restored by rework);
e1 RED/RED/RED and e7 RED/RED/RED (amended with the C3-mechanism
justification above). Informative: d2 green on `6cb370a` (single-flicker
pause/redemption worked for paused clocks in r7 — consistent with the same
nil-charge asymmetry that fails e1/e7 there).

Post-triage verification: full battery on the segment model = 13/13 green;
h3 re-run RED at t=30 on all three control worktrees; e1/e7 re-confirmed RED on
`6cb370a` with captured output. Controller performed this triage directly after
the triage agent was lost to two API interruptions; its uncommitted h3
same-batch groundwork was reviewed, extended (present-victim ingredient), and
incorporated.

## Round 9 (2026-08-01) — external cold-review fixes

### R9-F1 — barrier scoped by dependence (spec §4)

The round-9 cold review proved the pending-emission barrier over-broad: it
paused ALL current victims' whole ledgers whenever any lower owner's intent was
pending, recurring every emission cycle. Regime S9 (settled lower rewritten in
place emitting every ~3 ticks, stalled middle, ready high victim): the middle
blocker's running charge froze one tick per cycle, so the victim saw ~45s of
present-and-blocked wall time before write-off vs the [budget 30s, ceiling
30.4s] bound (probe measured 44s at 2s poll). Spec §4 qualifies the barrier by
dependence ("must not open, extend, consume, or write off successor-owner
segments **that depend on those pending owners**"). Fix: during a barrier pass,
only the PENDING owners' segments pause; non-pending running segments keep
accruing; opening/resuming the head's segment stays deferred; a write-off is
permitted iff the justifying ledger contains no pending owner's segment and the
head owner itself is not pending. End-of-pass settlement (absence pause /
discharge) untouched.

New battery probe: `test_S9_inPlaceRewritingLowerDoesNotDelayStalledBlockerWriteOff`
(driver-faithful S9 shape; asserts write-off within [budget, ceiling]+1 tick of
cumulative present-and-blocked wall time). Red-first evidence: on pre-fix code
the write-off landed at t=48 (45.0s of wall), failing the 31.4s bound; green at
t=33 (30.0s) after the fix.

### R9-F2 — write-off consumes the abandoned owner across ALL ledgers (spec-interpretation record)

Proven defect: with owner r_5 stalled over victims r_6 (justifier) and r_7, the
write-off consumed only r_6's ledger copy of owner 5. r_7's surviving copy then
let padding twin r_05 (same `RevisionKey`) resume the dead owner's segment with
the ORIGINAL `firstChargeNanos`: the twin was written off 0.0s after appearing,
logged "blocked for 30s", `consumedSegments=[]` — the same wall-clock stall
billed twice and a second frame lost (M2/M9 violations).

**Interpretation recorded for the maintainer's merge review:** spec §4 step 3,
"written-off owners consume the segments used to justify their write-off", is
read as consume-across-all-ledgers for the written-off owner's own segments.
The owner is abandoned; the write-off resolves ITS debt for every victim, not
only the justifier. This is the only reading consistent with M2 (a blocker
cannot be written off before its own charged interval plus explicit predecessor
debt reaches budget — a same-key successor inherits zero) and M9 (logs derive
from the decision, never from another owner's stale accrual). The justifier-only
reading leaves an unconsumable twin-bait copy; predecessor-debt consumption
(`consumedSegments`) remains justifier-ledger-only and truncating, since that is
the debt the decision explicitly claimed. Other owners' segments in non-justifier
ledgers remain owed per §5.2 and discharge on the next unblocked pass.

New battery probe: `test_S4_paddingTwinOfWrittenOffOwnerGetsFreshBudgetAndHonestAttribution`
(driver-faithful S4 shape: two victims, write-off, twin appears unready).
Red-first evidence: pre-fix, the twin was written off at t=31 — 0s after
appearing — with "blocked emissions for 30s" and no predecessor clause; post-fix
it survives to t=60 (29s own tenure + the named 1s of owner-6 debt,
"consumed predecessor debt: 6=1.0s").

### N2 — wall-clock invariant added to the sweep (round 9 instrument upgrade)

The N1 sweep (`testDriverFaithfulSweepHoldsTimingBoundInvariantsN1AndN2`) now
also checks N2: for every write-off decision, the justifying victim's
cumulative PRESENT-AND-BLOCKED wall time — accumulated by the harness from the
batches it constructs (present victim + batch-present unready lower on
pre-pass file states), never from reducer clocks — must be ≤ ceiling + one
poll tick. Owner-attributed time freezes during barrier pauses; wall time does
not, so N2 is the invariant that would have caught R9-F1 (N1 cannot: it is
anchored at `firstChargeNanos`, which the over-broad pause also freezes). The
reducer's test hook now passes the justifying victim's name alongside the
decision.

Wall re-anchor rules (each verified against sweep counterexamples before
adoption):
1. empty unredeemed ledger at a pass boundary (all past wait settled);
2. a yielded emission that redeems a segment the victim held (§5.3 chain case:
   sequential emitting blockers legitimately exceed one ceiling of wall time);
3. a write-off that consumed segments from the victim's ledger — adjudicated
   progress (checked AFTER the decision's own N2 assertion, so the triggering
   decision is still judged against pre-write-off wall time);
4. ticks whose wait is provisionally attributed to an in-flight emission (a
   pending owner holding a segment in the victim's ledger) are not counted:
   yield redeems and re-anchors; rejection makes the tick the spec's
   event-bounded barrier cost (§4). An R9-F1-style over-broad pause freezes
   charging while NO pending owner is in the ledger, so those ticks count.

A deterministic S9-family anchor (`testDriverFaithfulS9ShapeHoldsWallClockInvariantN2`)
pins sensitivity. **Sensitivity demonstration (performed once, then restored):**
with the R9-F1 fix locally flipped back to the whole-ledger barrier pause, the
sweep reported N2 violations across many runs (e.g. run 30: 33.0s, run 1415:
34.0s present-and-blocked) and the anchor failed with 45.0s wall vs the 31.4s
bound — the exact S9 signature. With the fix restored, all 8 property tests
pass.

### Round-9 control-matrix delta (new/changed battery tests only)

The current battery file was copied byte-identical into fresh worktrees at the
three control shas; only the two new probes (S9, S4) and the two changed probes
(d1 asserts, e9 cycle counts) were run (`swift test --filter`, one worktree at
a time; worktrees removed and pruned afterward).

| Battery test | `0ec11f8` (r6) | `6cb370a` (r7) | `fe843eb` (r8) |
|---|---|---|---|
| `test_S9_inPlaceRewritingLowerDoesNotDelayStalledBlockerWriteOff` (new) | pass | pass | pass |
| `test_S4_paddingTwinOfWrittenOffOwnerGetsFreshBudgetAndHonestAttribution` (new) | FAIL | FAIL | FAIL |
| `test_d1_...` (changed asserts) | FAIL (cell unchanged) | FAIL (cell unchanged) | FAIL (cell unchanged) |
| `test_e9_...` (cycles {2,5,20}) | FAIL (cell unchanged) | FAIL (cell unchanged) | FAIL (cell unchanged) |

Mechanisms:

- **S4 red ×3** — on every scalar sha the twin's write-off log reads "blocked
  emissions for 30s" where honest attribution is 29s own tenure plus a named
  1s of owner-6 debt ("Optional(30) is not equal to Optional(29)"; no
  "consumed predecessor debt" clause exists). Structurally guaranteed red: the
  scalar model has no consumedSegments concept, so the M9 log-honesty half of
  S4 is unrepresentable there.
- **S9 green ×3 — deviation from the round-9 expectation ("both new tests red
  on scalar builds"), recorded with mechanism.** S9 pins R9-F1, a defect in
  the pending-emission barrier — a segment-model mechanism THIS branch
  introduced; no scalar build has any barrier. In the S9 shape one episode
  (blocker 2, present victim) survives untouched from first charge to
  write-off, so each scalar sha's defect never engages: r6's over-broad
  ordering clear runs only at episode dissolution (episode never dissolves);
  r7's paused-only emission clear skips the victim's RUNNING clock (round-8
  C3 asymmetry — here that makes the clock accrue wall-continuously, which is
  the correct bound); r8's charge re-stamp targets the current episode
  blocker, which is already owner 2 (no-op). The scalar clock therefore
  charges wall-continuously and the write-off lands in [30s, 31.4s] — the
  green is mechanistically forced, not an accident of choreography. The
  segment-green half of S9 remains binding evidence for the R9-F1 fix
  (red-first proof: 45.0s pre-fix, 30.0s post-fix on this branch).
- **d1 / e9 red ×3, cells unchanged** — same first failures as the recorded
  matrix (d1: "successor written off at t=30s — inherited accrual"; e9:
  "cycles=2: premature write-off at t=30s"). The d1 assert change and e9
  extension did not flip any control cell (both fail in-loop before reaching
  the new asserts; e9's cycles=20 additionally shows three write-offs on
  scalar builds — the compounding class the probe pins).

**Timing recompute for barrier-adjacent probes (no asserts changed).** Re-derived
per the accrual comments: in e1, e7, e9, and h4 the non-pending owner's segment
is already PAUSED at every barrier tick — the transient occupant's own
`startOrContinue` paused it when it took the head slot (h4/d1/d9: the emitting
owner's segment is the pending one and pauses either way). R9-F1 changes only
RUNNING non-pending segments, which occur solely in the S9 family (a settled
in-place rewriter that never occupies the head slot). Expected write-off
instants therefore stay exactly d1: 36s, d9: 61s, e1: 33s, e7: 42s, h3: 43s,
h4: 56s, e9: 30+3·cycles — confirmed by a full battery run with zero edits to
existing expectations.
