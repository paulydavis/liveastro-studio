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

## Control-snapshot matrix (filled in by Task 10)

Binding rows (round-8 control table): d9 red on `6cb370a` only; e1/e7 red on
`0ec11f8` and `fe843eb`; h3/h4 red on all three. All other probes: record the
observed result per snapshot with a one-line explanation (informative, not binding).
