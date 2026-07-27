# LiveAstro Studio — Watcher Verification Round 8 & Clock-Model Spec (2026-07-27)

**Target:** commit `899a1d3..fe843eb` ("Fix watcher charge ownership timing"), main @ `fe843eb`.
**Method:** battery verifier with **both control snapshots** (round-7 `6cb370a` code substituted file-for-file; every discriminating claim carries a red/green counterfactual from the identical probe binary) + independent cold reader recalibrated with **timing-bound invariants** (the round-7 epistemics fix). Both refuted the fix; their findings interlock.

## VERDICT: FIX INTRODUCES REGRESSION — and the family CANNOT CONVERGE under single-scalar fixes

What the fix verifiably closes (control-proven): R7-1/d9 (fresh blocker 31.0s on fix vs 9.0s on control — both state and timing discriminated), R7-2 padding-tie asymmetry (symmetric on fix, asymmetric on control), the driver-faithful d9 test now exists and is red on control, the injected-state test is now driver-reachable, and the full legacy battery + 3000-run sweep hold (no fixed-only chaos violations; the 8 control-only hits are the closed d9 class).

But the accrual-time recharge equates "current episode blocker" with "owner of the accrual" — false whenever a transient converging file passes through the blocker slot — and the equality predicate makes unmatched charges permanently unclearable. Eight waves have now relocated the same misattribution: R5-2 victim-absent inheritance → R6-1 unrelated-emission clears → R7-1 structurally-unsatisfiable guard → R8-1 transient-owner hijack. **One clock with one charging-blocker label cannot represent accrual earned under multiple owners.**

## Section 1 — Cold findings (timing-bound invariants; all PROVEN)

**C1 (Important):** the clear runs only in the `activeBlocker == nil` branch (`WatcherFileState.swift:395-425`). If the charged owner emits while any unrelated episode is active, the paused clock survives its owner's emission → foreign accrual inherited → fresh blocker written off at **20s of its own tenure** (correct earliest: 30s). Fuzz: 52 post-emission violations / 400 runs; 92 clock-charged-under-settled-owner states.
**C2 (Important):** equality-only matching + the pause nil-guard makes a **vanished** owner's charge permanently unclearable — no future emission can ever match. Probe: victim accrues 29.5s under an owner that vanishes; brand-new blocker inherits it and is written off **0.5 seconds** after taking over, with the log claiming "blocked emissions for 30s."
**C3 (Minor, pre-existing):** running (present-victim) clocks never reset on owner emission — the fix's fresh-budget property exists only for the paused case.

## Section 2 — Battery findings (control-discriminated; all PROVEN)

**R8-1 (HIGH, regression — re-opens R6-1):** the per-scan recharge (`:611-613`, `:622-624`, `:631-633`) stamps the charge to the *episode blocker* = first non-ready in revision order — which is a fresh converging lower file for the 1-2 scans before it emits. Its emission then equality-matches and **wipes 27s of accrual charged for a still-live stalled blocker** (e1: 57s total hold vs control 3.0s/30s; e7: hold grows linearly with adversarial arrivals — unbounded pattern; control passes both).
**R8-2 (MEDIUM, fails both builds):** owner padding-renames during the victim's absence (r_1→r_01; pause preserves the stale charge) → its emission no longer equality-matches → d9 failure mode (9.0s write-off) survives.
**R8-3 (HIGH, pre-existing, identical both builds):** present-victim same-batch handoff — the ordered loop re-episodes to the new blocker *before* the old owner's emission executes, so both the `removeAll` and the discriminator are bypassed → the successor is written off **8.0s** after first being observed; one batch later and it is never written off (cliff). No flicker needed; the window is the old blocker's whole convergence tail. Chaos-corroborated (233 diagnostics/3000 runs, both builds).
**R8-4 (MEDIUM, pre-existing):** episode-age inheritance at clock creation (oldest-clock-governs) composes with paused-clock carry across write-offs → a victim can be born with ~28s of already-redeemed accrual and its next blocker written off after **0-3s of real blocking** (43/3000 chaos runs).

## Section 3 — Control counterfactuals (the arc's acceptance instrument)

| Probe | Round-6 (0ec11f8) | Round-7 (6cb370a) | Round-8 (fe843eb) |
|---|---|---|---|
| d9 fresh-blocker budget (R5-2 shape) | **31.0s ✓** | 9.0s ✗ | **31.0s ✓** |
| e1 unrelated-lower-emission hold | 57s ✗ (R6-1) | **3.0s/30s ✓** | 57s ✗ (R8-1) |
| e7 adversarial arrivals | grows ✗ | **36.0s ✓** | 53s, grows ✗ |
| h3 padding-rename-during-absence | 9.0s ✗ | 9.0s ✗ | 9.0s ✗ |
| h4 same-batch present handoff | 8.0s ✗ | 8.0s ✗ | 8.0s ✗ |

Each single-scalar predicate fixes one column and breaks another: round 6 cleared broadly (killed e1), round 7's guard was structurally dead (killed d9), round 8's equality+recharge resurrects e1 and leaves h3/h4 untouched. The pattern is complete evidence that the ambiguity is in the state model, not the guards.

## Section 4 — Clock model requirements (the redesign spec)

The mechanism's purpose, stated once: **bound how long a ready victim waits behind unready blockers, while never charging a blocker for time it did not cause.** Every requirement below is anchored to a proven probe; the battery for all of them exists and re-runs mechanically.

**M1 — Starvation bound (victim's guarantee).** Any victim whose *cumulative present-and-blocked* time reaches the budget must see write-off progress by the ceiling, regardless of blocker churn (alternation, padding, role swap, disjoint handoff), victim flicker of any length, or identity churn. [rounds 1-6 batteries; 83%-present 38s; multi-scan absence resume]
**M2 — Attribution (blocker's guarantee).** A blocker is written off only on the strength of wait-time attributed to *it* (or explicitly unresolved predecessors per M4) — never time redeemed by a resolved predecessor, never a transient slot-occupant's inheritance. Formally: no blocker is written off before (its first charge time + budget) of attributed time. [d9 9s; C2 0.5s; h4 8s; R8-4 0-3s]
**M3 — Absence pauses.** Victim absence of any duration pauses accrual (no aging, no destruction); the driver must keep reporting clock-bearing absent names (tombstones — proven composition requirement). [round-5/6]
**M4 — Redemption vs carry.** Accrual charged to an owner is **redeemed (cleared) when that owner resolves by emission**; an owner that *vanishes without emitting* does NOT redeem — its accrual carries as unresolved wait (d4/e8 semantics, deliberate). This is the d9-vs-d4 distinction every guard has fumbled: emitted = resolved, vanished = still owed.
**M5 — Same-batch ordering.** Redemption must be applied before the successor episode charges/adopts clocks within the same reduce pass (closes h4's bypass). [R8-3]
**M6 — Identity.** Owner and victim identity are keyed by **numeric revision**, stable across padding renames, at charge time and at redemption time. [h3, h7, padding twins]
**M7 — Transient occupancy.** A file that briefly occupies the blocker slot is charged only for the intervals it actually held it, and its emission redeems only those intervals — it cannot acquire or erase a co-existing stalled blocker's accrual. [R8-1/e1/e7]
**M8 — Hygiene.** All clock state: cleared at generation swap; bounded by present+tombstoned files; empty at quiescence; consumed by write-off; no leaks via droppedOutOfOrder or written-off owners. [sweeps H1/H2; g6]
**M9 — Log honesty.** A write-off log reports the written-off blocker's own attributed time, not episode or inherited time. [C2's lying log; round-4's "blocked 106s"]
**M10 — Composition proof.** Acceptance = the accumulated driver-faithful battery (with the round-6/7/8 control snapshots) + the 3000-run sweep with timing-bound invariants (N1: no write-off before first-charge+budget), run against the real synthesis rule. Reducer-only or injected-state tests do not count as evidence. [rounds 5, 7, 8 epistemics]

**Recommended shape (both reviewers converge; battery verifier's formulation):** replace the scalar clock+charge with **per-owner accrual segments** — the victim's wait recorded as segments keyed by the charging blocker's numeric revision. Emission redeems exactly the matching owner's segments (M2, M4, M6, M7); write-off decisions consume the total of remaining unredeemed segments (M1, preserves d4/e8 carry); segments inherited by a successor keep their original owner so later resolution still redeems them (closes R8-4); redemption ordered before successor charging in the batch (M5). Pause/tombstone machinery (proven this round) is retained as-is.

**Accepted/bounded residuals to carry into the design doc as documented decisions:** e9's 48s bounded write-off (non-growing, proven at 20/60/100 cycles); C3 running-clock non-reset on owner emission (decide: should M4 redemption apply to running clocks too — recommendation: yes, same rule, one code path); oldest-clock-governs multi-victim write-off semantics.

## Next step
Redesign from this spec (M1-M10 + segment recommendation), not another guard. The full battery and both control snapshots are retained in the session scratchpad (`fw8-watch/`, `fw8-ctl/`, `fw6-watch/`, `fw7-watch/`) and re-run mechanically against any implementation.
