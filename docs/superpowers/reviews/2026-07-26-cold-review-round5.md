# LiveAstro Studio — Fix-Wave Verification Review (Round 5 — Convergence Gate, 2026-07-26)

**Target:** commit `7ca016e..77a83cc` ("Fix round 4 review defects"), main @ `77a83cc`.
**Method:** 3 finding-armed verifiers (full accumulated batteries; driver-faithful watcher loops; wrong-space-cap sensitivity probes) + 1 cold diff reviewer. Paul's gates noted: 792/4-skip/0-fail, release + perf clean.

## Convergence verdict: 2 of 3 areas CONVERGED; the watcher needs one precisely-specified composition fix.

| Area | Verdict |
|---|---|
| **RCD pedestal (W4-1 Critical)** | **FIX VERIFIED — both classes closed.** Cap in correct space (a deliberately-wrong variant craters a saturated plateau to 0.421; production holds 1.0 — probe proven sensitive); spike class closed end-to-end (0 px < −0.05 in full default config vs round-4's ~1/1200; single-frame min −0.11 vs −1267); no bias reintroduced (medians ~1e-4); pedestal=0 path **byte-identical** to verified round-4 code; borders/seams/all-patterns/tiny-frames clean to 1e-6. |
| **Gate tail (W4-3)** | **FIX VERIFIED — semantics coherent and pinned.** Differential sweep: current output is a **strict subset** of round-4 on all 605/2000 diverging random sequences — the fix only removes dark-tail frames, no regression surface by construction. Terminal dark runs culled; bright tails preserved; legitimate terminal reseed survives at ≥7 frames; new tests uniquely discriminate the fix (round-4 code fails the dark-tail test, passes the bright-tail test). |
| **Victim clocks (W4-2)** | **FIX INCOMPLETE — one Critical remains** (below). Blocker side stays closed (full battery ~32s; 1500-seed sweep 0 violations); W4-2a fully closed (clocks cleared when unblocked, fresh blockers get full budgets, no lying logs); **single-scan** flicker closed (1-in-10 flicker emits at 33-40s). |

## R5-1 — CRITICAL, PROVEN (two reviewers independently, driver-faithful probes): pause-on-absence survives exactly ONE scan — multi-scan absence still destroys the clock and starves

Causal chain across three sites:
1. `WatcherFileState.swift:684` — `shouldPauseVictimClock` requires the victim to appear in **this batch's** observations; otherwise `retainVictimClocks` (:668) deletes the clock.
2. `WatcherFileState.swift:706-708` — `classify(.absent)` removes the file's `files` entry on the **first** absent scan.
3. `StackFileWatcher.swift:599-608` — the driver synthesizes `.absent` observations only for names still in `state.generation.files`.

So from the second consecutive absent scan the reducer never hears about the victim again and the "paused" clock is silently dropped. Proven: victim blocked 20s, absent 5 scans, returns → clock **restarted** (released 30s after return; reducer-only control with force-fed `.absent` every scan correctly resumes at 10s — the reducer semantics are right, **the composition with the driver is wrong**); victim present 83% of scans (10-present/2-absent cycle) → **never emitted in 800s, blocker never written off**; identity churn r_10↔r_010 likewise. The new pause test feeds exactly one absent scan — a shape the production driver can only deliver for single-scan flicker — so it pins the semantics while the composed system starves.

**Fix shape (verifier-specified, two options):** (1) keep a tombstone for clock-holding names so the driver keeps synthesizing `.absent` — consult `victimClocks.keys` in addition to `files.keys` at `StackFileWatcher.swift:600`; or (2) make `retainVictimClocks` treat "not in batch at all" as absent (pause) rather than as clear. Plus a driver-faithful multi-scan-absence test (the existing harness hand-feeds observations the driver cannot produce).

## R5-2 — MEDIUM, PROVEN: dissolution-by-emission while the victim is absent leaks the old clock into the next episode
`WatcherFileState.swift:557-565` + `:386-388`. When the victim is absent at the exact scan the old blocker emits, the episode was already dissolved (activeBlocker nil) so `reconcileActiveBlocker`'s `victimClocks.removeAll()` never runs; a stale paused clock then truncates a fresh blocker's budget (probe: written off 9.0s after appearing instead of 30s — W4-2a through a new door, narrow window).
**Fix shape:** clear paused clocks whose blocking context resolved by emission even when `activeBlocker` was already nil that scan.

## Low / hygiene (ledger)
- Vestigial episode-inheritance branch (`WatcherFileState.swift:580-586`) — analysis says unreachable; deletion candidate.
- Rejected-emission path (`:303`) leaves a clock entry uncleaned (state hygiene, no behavioral effect found).
- RCD: test gap — no test would catch a wrong-space cap (one saturated-star-on-negative-background test closes it); data-dependent pedestal driven by the single most-negative pixel (a −1e30 outlier quantizes the frame; clamp the pedestal) — theoretical.
- Gate: a session that truly ends dark still ends the replay on one black frame (spec-mandated always-keep-last); near-zero-calibrated terminal dropouts invisible below the 0.01 floor (pre-existing, characterized round 3); terminal regime changes need window+2 frames vs window+1 mid-stream (comment nit).

## Trend (five rounds)
25 findings → 3 structural classes → 2 of 3 converged with the strongest evidence of the arc (byte-identical unchanged paths, strict-subset differential proofs, 1500-seed sweeps). The watcher's remaining Critical is not a design failure — the reducer semantics are proven correct in isolation; the driver/reducer composition drops absent-file reporting one scan too early. Both fix options are one-site changes. **Wave 6 = R5-1 + R5-2 (+ optional hygiene), then a watcher-only round-6 verification with driver-faithful multi-scan-absence probes. That should be convergence.**
