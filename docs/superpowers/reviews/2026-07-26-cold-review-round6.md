# LiveAstro Studio — Watcher Convergence Verification (Round 6, 2026-07-26/27)

**Target:** commit `a86a923..9f0a4d8` ("Fix watcher paused victim clocks"), main @ `9f0a4d8`.
**Method:** one deep driver-faithful verifier (106 deterministic checks + 1500 seeds × 2 policies × 300 chaos batches with absence bursts) + one cold reader on the 22-line production diff. Both found the same remaining defect independently; the verifier's runtime evidence refines the cold reader's static analysis.

## Convergence line

**The blocking/starvation mechanism is structurally closed on both sides — blocker churn AND victim lifecycle including multi-scan absence — with the driver+reducer composition proven, not just the reducer.** Both round-5 defects are verified closed with driver-faithful probes, including a legacy-driver control proving the delta is the driver change (not a reducer accident). Sweep: **0 violations in 3000 runs** across ordering, dedup, high-water, liveness, bounded blocking, and two new map-hygiene invariants (clock map bounded, empty at quiescence). Starvation-to-infinity is dead.

**One Medium remains — introduced by this wave's R5-2 clear — with a single-site fix specified.** It is bounded-per-event budget restart, not clock deletion: not the round-5 Critical class.

## Verified closed (all PROVEN, driver-faithful)
- Blocked 20s → absent 5 scans → return: released **10.0s** after return (resume). Legacy-synthesis control: 30.0s (restart) — the driver tombstone is what fixed it.
- 83%-present victim: emitted **38.0s** (round 5: never in 800s, blocker immortal).
- Identity churn r_10↔r_010: bounded (62.0s).
- R5-2 repro: fresh stalled blocker after dissolution-during-absence → full **31.0s** budget (was 9.0s).
- Entire six-wave regression battery green (alternating blockers, padding churn, role swap, disjoint handoff, grace ceiling, oldest-clock, W4-2a regimes, flicker, blocker-swap-during-absence, generation swap).
- Tombstone mechanism sound: permanently-deleted victims cost exactly one paused clock and zero churn (`classify(.absent)` without a files entry is a no-op); cleanup proven on all three resolution paths; no growth (map empty at quiescence in all 3000 runs); generation swap kills tombstones; padding twins get their own budgets; paused tombstones never drive write-offs.
- Both new tests are genuine red-first discriminators (round-5 code fails each for the intended reason).

## R6-1 — MEDIUM, PROVEN (both reviewers): the emission-time clock clear lacks a charging-blocker discriminator
`WatcherFileState.swift:413-425` (reached from :383-386). When all of a still-live blocker's victims are absent in a scan, the episode dissolves with clocks retained; any numbered emission from that batch then clears every paused clock ordered above it — including clocks whose accrual was charged under the **still-present, still-unready blocker** sitting between the emitted revision and the victim. Runtime evidence: victim accrued 27s under live stalled r_5; unrelated fresh r_3 emits on the one scan the victim flickers absent → clock cleared → 57s total present-blocked vs the 32s ceiling; the settled-replacement re-emission path triggers the same clear; worst case (one lower numbered file rewritten in place, re-emitting each cycle, victim flickering on those scans) reached ~70s cumulative blocked with zero write-off progress and extends per event. Adversarial for Siril's write-once numbered outputs — hence Medium, not Critical. Round-5 code handled this exact regime correctly (regression).

**Refinement over the cold reader's static analysis:** the function is NOT purely harmful — in the R5-2 named repro (fresh stalled blocker present in the same batch) the dissolution branch is taken, the observe-pass `removeAll` never runs, and the clear is live and necessary (it's what restored the 31s budget). It just clears too broadly.

**Wave-7 fix (single site, keeps every green test green):** when dissolving an episode with retained clocks (:574-581), record the blocker (name/revision) the clocks are charged under; in the emission-time clear, remove a clock only when the emitted candidate is, or is ordered at/after, that charging blocker. The verifier's probe battery is retained at the scratchpad `fw6-watch/` for immediate re-run.

## Hygiene ledger (unchanged, non-blocking)
- Vestigial episode-inheritance branch (now `WatcherFileState.swift:596-603`) — deletion candidate.
- Rejected-emission clock entry (:303) not cleared — self-heals next scan; hygiene only.
- Blocker-transiently-absent-while-victim-absent resets the paused budget via the empty-scan `removeAll` (cold reader, theoretical; pre-existing branch — bounds the pause guarantee to scans where the blocker stays visible).
- Separately ledgered per Paul: leaked-continuation runtime diagnostic from an unrelated BroadcastController test (CheckedContinuation class; investigate on next OBS touch).

## Board status after six rounds
Round-1 board: 3 Critical + 22 Important. Now: **one Medium with a specified one-line-shaped fix, plus a minors/hygiene ledger.** RCD (both classes), FrameSelector, GraXpert, import lifecycle, OBS socket, detectors (as-designed), and the watcher's starvation mechanism are all closed with probe evidence. Wave 7 = the charging-blocker discriminator; round 7 = re-run the ready battery. That is the finish line.
