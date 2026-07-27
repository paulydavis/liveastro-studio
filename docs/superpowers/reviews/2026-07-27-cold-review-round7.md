# LiveAstro Studio — Watcher Final Verification (Round 7, 2026-07-27)

**Target:** commit `0ec11f8..6cb370a` ("Fix watcher paused clock blocker discriminator"), main @ `6cb370a`.
**Method:** battery re-run verifier (fw6 harness + round-6 control snapshot at 0ec11f8) + independent cold reader.

## VERDICT: NOT CONVERGED — R6-1 is closed, but the discriminator re-opens R5-2

The reviewers split, and adjudicating the split is the finding:
- The **cold reader** returned "no refutation found" (first time in seven rounds): every constructor site clean, 6000-seed fuzz clean, charge-recharge discipline closes stale-charge regimes. It *observed* that the predicate's clearing arm is driver-unreachable but graded it "defensive, not wrong" — its invariants didn't encode the d9 budget requirement, and its drain-liveness check can't distinguish a 9s write-off from a 31s one.
- The **battery verifier** carried the historical d9 control and proved the regression: on round-6 code the R5-2 repro gives the fresh blocker its full **31.0s** budget; on this commit it is **written off 9.0s after appearing** — premature frame loss. The clear that round 6 proved "live and necessary" can now never fire.

**Adjudication: the battery verifier wins — runtime proof with a version-controlled counterfactual.** This is also the arc's clearest demonstration of why the accumulated battery re-runs every round: a green 795-test suite and a clean cold read both missed it, because the only test pinning d9's necessary clear was replaced this wave with one that injects a state the driver cannot produce.

## R7-1 — HIGH, PROVEN: charge-at-pause-time ownership makes the necessary clear structurally unsatisfiable
`WatcherFileState.swift:41-46` (pause overwrites `chargingBlocker` unconditionally — line 45 sits outside the `pausedAtNanos == nil` guard), `:692-708` (`retainVictimClocks` re-pauses every surviving clock during the scan), `:421-439` (the clear). Because the scan re-stamps the charge to the **current batch's blocker** before `emissionFinished` arrives, and every emission in a batch is strictly `orderedBefore` that blocker by construction, the guard can never pass in composition — the clear is dead code at runtime. Consequences, proven: d9 (victim accrues 22s under converging r_1; r_1 emits while the victim flickers absent and stalled r_2 arrives same batch) → r_2 inherits the foreign 22s accrual and is written off at **9.0s** (round-6 control: 31.0s). Any legitimately slow-converging new revision arriving in that batch loses its frame.

What IS closed, same commit (all proven): every R6-1 shape — e1 (release 3.0s after return, total ≈30s ≤ ceiling), e6 (8.0s), e7 (36.0s despite six timed lower arrivals), e9 (write-off bounded at 48.0s, identical at 20/60/100 rewrite cycles — the unbounded-reset source is gone). Full six-wave battery otherwise green (119/121; the two fails are d9 and a miscalibrated e9 bound, recalibrated). Sweep 0/3000. Tombstone lifecycle clean. New repro test genuinely red on round-6 code.

**Round-8 fix direction (verifier-specified, one site):** stamp `chargingBlocker` at **accrual time** — set/refresh it to the active episode's blocker while the victim is a present victim (clock running), and make `pause()` preserve an existing charge instead of overwriting. Then in d9 the charge still names the old blocker (its emission matches → clear fires, full budget restored); in e1 the charge is the still-live stalled blocker (retain holds); d4's vanished-owner carry is preserved (a vanished owner never emits). Prefer name+revision **equality** on the recorded owner over `orderedBefore` (closes the R7-2 padding-tie asymmetry below). **And add a driver-faithful d9 test** — the necessary clear is currently pinned by no test, which is exactly how this slipped through a green suite.

## Minor / theoretical
- **R7-2 (LOW, THEORETICAL):** `orderedBefore` tie-break asymmetry — emission of a distinct padding twin (`r_5` vs charged `r_05`, numerically equal) clears in one direction, retains in the other. Unreachable in the current composition; latent for any future caller. Equality matching in round 8 closes it.
- Cold reader's notes: one belt-and-braces guard that can never fail (`:698`); the updated positive clear test (`WatcherReducerTests.swift:2143-2158`) pins a driver-unreachable injected state — replace it alongside the round-8 fix.

## Board status
Everything else from seven rounds remains closed (RCD both classes, FrameSelector, GraXpert, import lifecycle, OBS socket, tombstones, blocker-side starvation, R6-1's extension side). The watcher family needs **one more targeted pass** on charge ownership — precisely specified, one site, with the battery (now including the recalibrated e9 and the restored d9 discipline) ready in the scratchpad for round 8.
