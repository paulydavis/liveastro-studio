# Segment-Model Implementation Plan — Review (2026-07-30)

**Plan:** `docs/superpowers/plans/2026-07-27-watcher-clock-segment-model-implementation.md` (9b9be00)
**Spec:** `docs/superpowers/specs/2026-07-27-watcher-clock-segment-model-design.md` (binding)
**Method:** two independent reviewers — spec conformance (every normative clause walked against the plan; environment facts verified in-repo) and code correctness (every embedded Swift block checked against the real sources; pure types probe-compiled; test arithmetic recomputed).

## VERDICT: REVISE

The model core is right: the Task-2 primitives are probe-verified sound (RevisionKey normalization/ordering, one-running-segment invariant, accrue/pause/redeem totals), the §3 types match the spec exactly, redemption/discharge/barrier semantics are faithfully stated, and reconciliation-first ordering is honored. What needs revision splits into three themes.

---

## Theme 1 — The acceptance gate is missing its refutation half (conformance B1-B3)

The gate is the reason this spec exists, and the plan currently produces only green evidence.

- **B1: No control snapshots.** Task 8 claims red/green counterfactual proof but never obtains, builds, or runs the round-6/7/8 control code. The control commits (`0ec11f8`, `6cb370a`, `fe843eb`) all exist in history — the plan needs explicit steps: extract the control `WatcherFileState.swift`, substitute file-for-file into a scratch checkout, run the same probes, record the expected reds per the round-8 table.
- **B2: The fw6/fw7/fw8 batteries no longer exist** (session scratchpad is gone — verified) and the plan never mentions them; six hand-picked probes silently replace "the reconciled accumulated batteries." Decide explicitly: port/regenerate the battery harness into `Tests/` (recommended — it then runs mechanically forever), or amend the gate in the reconciliation doc with a per-probe coverage map and justification.
- **B3: The 3000-run N1 sweep isn't reproduced.** The plan points at the existing 1,000-transition *reducer-only* property loop (demoted by M10), provides no wiring for the sweep to observe write-off decisions, and its N1 predicate drops the "grace expired" conjunct — any nonzero predecessor debt excuses any premature write-off, degenerating N1 into restating the implementation.

## Theme 2 — The observe-driven tests don't model the watcher's own digest gate (code B1, B2, B3)

- **B1: Every observe-driven emission test in Tasks 5 and 8 expects emission after a single `.digested` sighting** — impossible under `.mutableStackerOutput`: `reduceStableDigest` parks the first sighting in `.digestPending`; a second same-digest sighting ≥ quietPeriod later is required (the repo's own tests pin this). All six driver-faithful acceptance tests fail as written, and their use of `.identityUnchanged` for `.digestPending` files means "resolving" blockers never become ready at all. Fix: two-sighting choreography throughout (or injected `.ready` states in reducer-only development probes only).
- **B2: The discharge predicate consults only `files` — but an `.invalid` observation with no prior state never enters `files`** while still being an unready blocker in `orderedEffects`. A victim behind an invalid lower revision (the canonical incomplete-file blocker, used by nearly every test helper) is judged "unblocked" and discharged every pass — unbounded starvation, and the plan's own Task-6 test fails against its own implementation. Fix: derive blockedness from the classified batch (the same evidence `orderedEffects` uses), per the spec's file-state definition.
- **B3: `.folderGenerationChanged` doesn't exist** — the command is `.replaceGeneration`. Compile error in Task 3's first test.

## Theme 3 — The migration leaves the hardest code unspecified and resurrects the original defect (code I1-I7)

- **I3 (the sharpest finding): a mechanical rename keeps `victimClocks.removeAll()` at the three `reconcileActiveBlocker` sites — wiping OTHER owners' unredeemed segments on blocker emission.** That is verbatim failure-mode #1 from the spec's §1 (broad emission-time clearing), silently reintroduced — and the plan writes no d4 test that would catch it. Fix: replace `removeAll()` with owner-keyed `redeemSegments` + victim-own-emission clear, and add the d4 driver-faithful test.
- **I2: the four-line call-mapping table doesn't cover the ~100-line `orderedEffects` charging/write-off block** (episode inheritance, converging renewal, deadline gating, heldSeconds log) — implementers transcribing verbatim have nothing to transcribe for the hardest region. Spell out the replacement block or explicitly stage it as wholesale replacement in Tasks 4/7 with the interim Task-3 shape defined.
- **I1: `StackFileWatcher.swift` must change (tombstone synthesis reads `victimClocks.keys` at line 589-590) but appears in no task's file list** — nothing compiles after Task 3 without it.
- **I4: Task 7's logging code doesn't compile** (`log(.frameLost(...))` and `formatNanos` don't exist; effects are `WatcherEffect.log(String)`).
- **I5 (proven by probe): log-honesty bug — `consumedSegments` includes the current blocker's own segment, so its own 0.5s prints under "predecessor debt"** — violating the exact M9 separation the plan's Global Constraints state. Exclude the blocker's key from the predecessor map.
- **I6 (proven by arithmetic): the only convergence-grace test is vacuous** — with quiet=5s the budget is 50s and total unredeemed is 34.5s, so the write-off guard returns nil before grace is ever consulted; §5.4's grace path has zero test coverage. Re-pick constants so total ≥ budget with the owner inside its renewed grace.
- **I7: Task 3's "compile succeeds" expectation is unachievable** — ~10 unenumerated test-file sites still construct the removed types (`BlockingEpisode(blocker:startNanos:...)`, `VictimBlockingClock`, `activeBlocker?.startNanos`); `--filter` still compiles the whole module. Enumerate them with new expected values.

## Conformance Importants (fold into the revision)

- Victim's-own-emission discharge is a stated Global Constraint but no task implements or tests it.
- The two new maps (`pendingEmissionOwners`, `ownerGraceUntil`) have no cleanup on redemption/write-off/vanish and no generation-swap/quiescence assertions — M8 hygiene gap.
- Log honesty is untested at the log level (the reconciliation table's own d4 row requires it); ScriptedWatcherDriver collects logs no test reads.
- No driver-faithful vanished-owner-carry probe — the C2 0.5s counterexample has zero composition coverage.
- No branch strategy; repo sits on main. Add: feature branch before Task 1; merge only after the round-9 external verification.
- StackFileWatcherTests declared in Files/`git add` but never edited (both-directions scope drift).

## Minors (both reviewers, deduplicated)

Redemption snippet needs the generation-id check and has two insertion sites (settlement via replacement AND ready paths); budget formula re-hardcoded instead of reusing `blockingBudgetNanos` (values match today — drift hazard); `consume()` deletes whole segments while the decision records partial amounts (state the choice explicitly per §5.6's escalation rule); convergence-grace hookup names no exact call site and lacks a churn-does-not-renew test; Task 3 commits with unenumerated expected-red tests; reconciliation table omits the round-8 cold probes C1/C2/C3; the plan's own Task-2 test sorts RevisionKeys lexicographically (the precise anti-pattern §3.1 bans); zero-amount consumption entries pollute the decision map; barrier guard's early `return` could skip the end-of-pass pause/discharge loop (tighten to the segment-ops branch).

## What checked out

All consumed symbols exist as written (no name drift against real code); grace/budget/ceiling constants match `WatcherReducer` exactly (30s floor, 10×quiet, 5×poll, grace=quiet, ceiling=budget+4×quiet); Task 7 Step 1's write-off arithmetic verified; the discharge predicate correctly avoids episode/barrier state (its bug is the `files`-only evidence, not the independence); `.replaceGeneration` preserving `lastEmittedDigestByName` anchors match; primitives probe-clean.

## Suggested revision order

1. Fix the three code Blockers (two-sighting choreography, batch-derived blockedness, command name) — they invalidate most tests as written.
2. Specify the `orderedEffects`/`reconcileActiveBlocker` replacement (I2+I3) — the semantic heart.
3. Rebuild the acceptance gate (conformance B1-B3): port the battery harness into `Tests/`, add control-snapshot steps, specify the driver-faithful N1 sweep with the two-condition exception.
4. Fold in the Importants (own-emission discharge, map hygiene, log-level honesty test + I5 fix, d4/C2 probe, branch strategy, file lists).
5. Minors in one pass.
