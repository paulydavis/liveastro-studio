# Watcher Clock Segment Model — Merge Package (2026-08-01)

**Branch:** `feature/watcher-segment-clocks` @ `4f05fc8` — 17 commits over main, pushed.
**Spec:** `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md` (M1–M10).
**Status: CLEAR FOR MERGE — decision is the maintainer's.**

## What this branch does
Replaces the watcher's scalar victim-blocking clock (the mechanism behind eight rounds of starvation/attribution defects) with per-owner accrual segments: `VictimWaitLedger`/`AccrualSegment`/`RevisionKey`, owner-keyed redemption on yielded settlement only, pending-emission barrier (dependence-scoped), tombstone pause / batch-derived discharge, two-condition write-off (`WriteOffDecision`) with per-owner convergence grace and honest attribution logging. `StackFileWatcherTests` (57 tests, the driver-level contract) passes **unmodified** — zero edits to that suite across the entire branch.

## Verification chain (all first-hand evidence, three independent verifiers)
1. **Plan execution:** 11 tasks, red-first throughout; two plan defects caught by implementers' stop-rules mid-execution (Task 6 mispredicted red branch; Task 9's h3 choreography) — both resolved with recorded deviations, never rationalized.
2. **Acceptance gates (Task 11):** battery 13/13; control counterfactuals at three historical scalar commits with every binding row matched or amended on line-verified mechanism evidence; 3000-run N1 sweep with proven sensitivity (1,157 violations under deliberate weakening); full suite; release build.
3. **Round-9 external verification:** instrument A independently re-established every gate (GATE CONFIRMED); instrument B (cold, timing-bound invariants) found two proven Importants the batteries didn't encode:
   - **R9-F1** — barrier paused non-dependent segments (victim wall-clock 44–45s vs the [30, 32]s bound under in-place lower rewriting). Root cause: the spec's §4 dependence qualifier was lost between spec and implementation.
   - **R9-F2** — a padding twin of a written-off owner inherited the dead file's tenure (written off 0s after appearing, logged "blocked for 30s", debt double-consumed).
4. **Fix wave (5 commits):** both fixed red-first with driver-faithful pins (S9: 45s red → 30.0s green; S4: 0s-twin red → t=60 green with honest predecessor clause); four code minors + battery nits; **N2 added to the sweep** — the victim wall-clock invariant that would have caught R9-F1 (N1 measures owner-attributed time, which pauses legitimately freeze; wall time is the user-visible bound).
5. **Focused re-verification:** F1/F2 counterfactuals reproduced against the pre-fix commit via git; the N2 re-anchor rules audited adversarially (SAFE — the first rule triggers only on the exact negation of the R9-F1 condition; no masking scenario constructible); production delta read for over-correction (none); suites re-run: battery 15/15, reducer 84/84, property 8/8 (N1+N2), StackFileWatcher 57/57, **full suite 832/4-skip/0-fail**, release clean, diff-check clean.

## Item requiring maintainer sign-off
**Spec interpretation (recorded in the reconciliation doc):** §4 step 3's "written-off owners consume the segments used to justify their write-off" is implemented as **consume the written-off owner's segments across ALL victims' ledgers** — the only reading consistent with M2 (no double-billing of the same wall-clock stall) and M9 (honest logs). If you prefer the narrow reading, R9-F2's instant-twin-execution returns; approving the merge approves this interpretation.

## Minors carried to the post-merge ledger (none block)
- During a barrier pass, `noteConvergingOwner` is skipped while write-off remains possible — a converging head can lose one grace renewal on a barrier tick (one-tick window, ceiling-capped).
- A pending head owner with no lower pending owner bypasses both barrier checks (pre-existing predicate, identical at the pre-fix commit; one-pass race).
- e9 battery cycles now {2, 5, 20} (historical probes used up to 100; linear-shape assert retained).
- S9 is green on all scalar control builds — mechanistically forced (scalar clocks charge wall-continuously in that shape); its red/green counterfactual is the pre-fix branch commit, reproduced.
- Round-9-A battery notes resolved in the fix wave (d1 vacuous assert, c3/S5 redundant bounds).

## Merge mechanics (when approved)
```
git checkout main && git pull
git merge --no-ff feature/watcher-segment-clocks
swift test          # expect 832/4-skip/0-fail
git push
```
Post-merge suggestions: repackage dist app when convenient; the reducer's own docs (`docs/superpowers/specs`) already carry the model; consider a real-sky session before the next release tag.
