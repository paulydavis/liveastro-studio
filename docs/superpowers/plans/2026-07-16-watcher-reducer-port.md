# Watcher Reducer Port (Phase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> Requirements source of truth: `docs/superpowers/specs/2026-07-16-watcher-state-model-and-reseed-contract-design.md` §1–§2 (the four pins are binding).

**Goal:** replace StackFileWatcher's eight per-name ordering/dedup maps with the
per-file `FileState` machine + two typed side tables, mutated only in a
synchronous reducer — behavior-identical per the conformance oracle.

**Architecture:** observe phase (pure reads on pinned descriptors, producing
complete per-file observations) → reduce phase (one synchronous pass on the
watcher queue applying observations to the state table; the only mutation
site). `BlockingEpisode` is a single optional value derived per pass
(victim-defined existence, spec §2.3). Emission happens from reducer output,
after the pass.

## Global Constraints (verbatim from spec)
- Evidence types: `emittedThisGeneration: Set<String>` (ordering, dies with
  generation) vs `lastEmittedDigestByName: [String: String]` (dedup,
  latest-per-name, survives generations). `contentDigestsEverEmitted` must not
  appear anywhere.
- Episode invariant: exists iff head-of-line revision fails to emit AND ≥1
  later never-emitted numbered revision present; lone-period teardown is
  load-bearing; duplicate-settles-while-held stops counting as a victim.
- Absence semantics: `observing`/`digestPending`/`ready` die on absence;
  `settled`/`droppedOutOfOrder`/`writtenOff` immortal within the generation;
  high-water mark derived from `settled(.emittedNow)`.
- Both settlements carry `FileIdentity` and arm the fast-path (classic file
  exempt — permanent rehash).
- Classic transitions: `settled → digestPending` on digest change;
  settle-back-to-last-emitted lands `duplicateOfLastEmission`, pending
  evidence consumed.
- Budget/grace/ceiling semantics unchanged (budget = max(30s, 10×quiet,
  5×poll); grace = 1×quiet per converging observation; ceiling = budget +
  4×quiet; churn never resets; written-off names never emit within the
  generation).

## Conformance oracle (named — editing any of these = semantics drift, STOP)
`testMutablePolicy_loneBlockerPeriodNotCharged_freshClockPerBlockingEpisode`,
`testMutablePolicy_writeOffLogReportsEpisodeDuration_notLoneWallTime`, the
oscillator/ceiling pair, the mark-drop tests,
`testMutablePolicy_pauseSpansBothObservations_hybridEmits_acceptedBoundary`,
the `digestComputations` cost-model test (fast-path flatness) — plus the full
watcher suite (currently green at 641/3/0 on `b5d21bd`). Harness-mechanical
edits only; any assertion change is a finding to escalate, not adapt.

### Task 1: State model types + pure reducer
- Create: `Sources/LiveAstroCore/Watch/WatcherFileState.swift` — `FileState`,
  `Settlement`, `BlockingEpisode`, `FileObservation` (the observe-phase
  output: stat/header/digest results or absence/invalidity), and
  `WatcherReducer` (pure: `(states, observations, clock, policy, config) →
  (states', emissions, logs, episode')`).
- Test: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift` — unit tests per
  transition table incl. all four pins, driven with synthetic observations
  (no filesystem). Red-first per case.
- The reducer must compile with zero references to filesystem APIs.

### Task 2: Port the scan loop
- Modify: `Sources/LiveAstroCore/Watch/StackFileWatcher.swift` — scan() becomes
  observe (existing pinned-descriptor reads, unchanged) + one reducer call +
  emission of reducer output. Delete `lastSeenStat`, `pendingContent`,
  `emittedRevisionHighWater`, `outOfOrderDropLogged`, `blockTracks`,
  `writtenOffRevisions`, `lastEmittedIdentity` as separate maps (identities
  ride Settlement payloads; dedup table renamed `lastEmittedDigestByName`).
  Generation reset = clear state table + episode (dedup table survives).
  Stop-abort, bounded-stop, lifecycle, FIFO/type guards untouched.
- Gate: full watcher suites (`StackFileWatcherTests`, `FaultMatrixFileTests`)
  green with ZERO assertion edits; then the FULL suite; then release build.

### Task 3: Property pins (five)
- Test: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`:
  (1) reducer never emits a numbered revision ≤ any `settled(.emittedNow)`
  revision in-generation; (2) episode exists iff the invariant's predicate
  holds (random state tables); (3) evidence-type separation: dedup table
  content can never affect blocker accounting or the mark (construct the
  review-12 P1-1 scenario generically); (4) role round-trips never inherit
  clocks; (5) terminal states are immortal within a generation **under
  absence specifically** (absence observations against terminal states are
  no-ops).

Final: whole-branch review + both cold lenses run AFTER phases 2–3 complete
(one combined gate per the approved sequencing), not per-phase.
