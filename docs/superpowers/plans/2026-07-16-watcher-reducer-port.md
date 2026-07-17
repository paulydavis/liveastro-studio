# Watcher Reducer Port (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `StackFileWatcher`'s interacting ordering, stability, dedup,
identity, and write-off collections with one reducer-owned `WatcherState`, while
preserving every shipped watcher behavior and closing the two review-12 watcher
P1 traces structurally.

**Architecture:** The watcher driver asks the reducer for a read plan, gathers a
complete immutable observation batch through the existing pinned descriptors,
and submits that batch as one command. The reducer is the only semantic mutation
site. It returns generation-tagged log and emission intents; their results return
as reducer commands, so an intent from an old folder generation cannot settle in
the current one. `WatcherState` has an outer latest-digest-by-name table and a
replaceable `GenerationState`; ordering evidence is derived from terminal file
states and never stored separately.

**Tech Stack:** Swift 5.9+, Swift Package Manager, XCTest, Foundation,
`StackFileWatcher`'s existing POSIX descriptor layer and injectable monotonic
clock.

**Requirements source of truth:**
`docs/superpowers/specs/2026-07-16-watcher-state-model-and-reseed-contract-design.md`
§1–§2. The four approved pins and all current watcher tests are binding.

## Global Constraints

- Work only on phase 1. Do not change `StackEngine`, session manifests, the
  fault oracle, OBS code, or the phase-2 reseed/master contract.
- Preserve `StackFileWatcher`'s public initializer and callback surface.
- Preserve pinned-directory enumeration, `O_NONBLOCK | O_NOFOLLOW`, regular-file
  rejection, before/after `fstat` torn-read detection, FITS completeness checks,
  SHA-256 calculation, debounce, lifecycle, and bounded-stop behavior.
- The pure state-model file may use value types such as `URL` and
  `FileIdentity`, but must not call `FileManager`, `open`, `stat`, `read`, or any
  other filesystem API.
- There is one authoritative mutable value:

  ```swift
  struct WatcherState {
      var generation: GenerationState
      var lastEmittedDigestByName: [String: String]
  }
  ```

- `GenerationState` is replaced as a whole on disappear/return, re-arm, or
  directory identity replacement. Its `FolderGeneration` is monotonically
  increasing even if `(dev, ino)` is reused. The outer digest table is the only
  semantic state that survives.
- Generation-local emitted evidence is a projection of immortal
  `.settled(.emittedNow(...))` states. Do not store a second set or a mutable
  high-water mark.
- Both settlement variants carry the exact `FileIdentity` and digest that
  settled. They arm the immutable/numbered identity fast path. The classic
  fixed-name mutable file always rehashes.
- `observing`, `digestPending`, and `ready` die on absence. `settled`,
  `droppedOutOfOrder`, and `writtenOff` are immortal until generation
  replacement.
- `activeBlocker` exists iff the head-of-line nonterminal numbered revision
  cannot emit and at least one later nonterminal potential victim is present.
  Victim disappearance destroys the episode even if the blocker remains.
- Preserve the existing blocking budget, convergence grace, hard ceiling,
  logging text, and clock units exactly. Identity churn alone never resets or
  extends the episode.
- The latest digest is per filename. A→transient B→A emits nothing;
  A→emitted B→A can emit A after earning stability again.
- Do not alter assertions in the existing conformance suite. Harness-only edits
  must be called out in the task commit. An assertion mismatch is design drift:
  stop and report it.
- Before any SwiftPM command, verify no other process or agent owns this repo's
  build lock. Never overlap SwiftPM runs in this repository.

---

## Task 1: Introduce the pure reducer and pin its state invariants

**Files:**

- Create: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Create: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Reference only: `Sources/LiveAstroCore/Watch/StackFileWatcher.swift`

### Interfaces to implement

Keep these internal to `LiveAstroCore`. Equivalent case labels are acceptable
only if the payloads and ownership boundaries remain identical.

```swift
struct FolderGeneration: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

struct WatcherState {
    var generation: GenerationState
    var lastEmittedDigestByName: [String: String]
}

struct GenerationState {
    let id: FolderGeneration
    var files: [String: FileState]
    var ordering: RevisionOrderingState
}

struct RevisionOrderingState {
    var activeBlocker: BlockingEpisode?
}

enum FileState: Equatable {
    case observing(stat: FileIdentity)
    case digestPending(PendingDigest)
    case ready(EmissionCandidate)
    case settled(Settlement)
    case droppedOutOfOrder
    case writtenOff
}

struct PendingDigest: Equatable {
    let digest: String
    let identity: FileIdentity
    let firstObservedNanos: UInt64
}

enum Settlement: Equatable {
    case emittedNow(identity: FileIdentity, digest: String)
    case duplicateOfLastEmission(identity: FileIdentity, digest: String)
}

struct BlockingEpisode: Equatable {
    let blocker: String
    let startNanos: UInt64
    var deadlineNanos: UInt64
}
```

Define reducer inputs and outputs explicitly:

```swift
struct WatcherReducerConfiguration {
    let digestPolicy: StackFileWatcher.DigestPolicy
    let filePrefix: String?
    let quietPeriodNanos: UInt64
    let pollIntervalNanos: UInt64
}

enum WatcherEntryKind: Equatable {
    case classicMutable
    case numbered(revision: String)
    case immutable
}

struct EnumeratedEntry: Equatable {
    let name: String
    let url: URL
    let identity: FileIdentity
    let isFITS: Bool
}

enum ReadRequest: Equatable {
    case acceptIdentity(FileObservation)
    case readContent(name: String, url: URL, kind: WatcherEntryKind,
                     identity: FileIdentity, isFITS: Bool)
}

struct FileObservation: Equatable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let outcome: ObservationOutcome
}

enum ObservationOutcome: Equatable {
    case absent
    case invalid(reason: String)
    case unstable(identity: FileIdentity)
    case identityUnchanged(identity: FileIdentity)
    case digested(identity: FileIdentity, digest: String, byteCount: Int)
}

struct EmissionCandidate: Equatable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let identity: FileIdentity
    let digest: String
    let byteCount: Int
}

struct ObservationBatch: Equatable {
    let generation: FolderGeneration
    let entries: [FileObservation] // complete batch, including tracked absences
    let nowNanos: UInt64
}

enum WatcherCommand {
    case replaceGeneration(FolderGeneration)
    case observe(ObservationBatch)
    case emissionFinished(EmissionResult)
}

struct EmissionIntent: Equatable {
    let generation: FolderGeneration
    let candidate: EmissionCandidate
}

struct EmissionResult: Equatable {
    enum Outcome: Equatable { case yielded, rejected }
    let intent: EmissionIntent
    let outcome: Outcome
}

enum WatcherEffect: Equatable {
    case log(String)
    case emit(EmissionIntent)
}

struct WatcherReducer {
    private(set) var state: WatcherState
    let configuration: WatcherReducerConfiguration
    mutating func reduce(_ command: WatcherCommand) -> [WatcherEffect]
    func readPlan(for entries: [EnumeratedEntry]) -> [ReadRequest]
}
```

The reducer owns the one anchored revision parser, constructed from
`configuration.filePrefix`; `readPlan` attaches its classification to each
request, and the driver copies that classification into the resulting
observation. `readPlan` runs after the driver's cheap open/`fstat` step. It may
select `.acceptIdentity` only for a settled immutable or numbered entry whose
current identity equals the settlement payload. Every other regular entry gets
`.readContent`; open/stat/type failures become `.invalid` observations directly
and do not enter the read plan. This keeps the policy decision pure without
moving descriptor ownership into the reducer.

`EmissionResult` must contain the original generation-tagged intent and whether
the driver actually yielded it. Only a successful, current-generation result
may transition `.ready` to `.settled(.emittedNow)` and overwrite
`lastEmittedDigestByName[name]`. A stale result is a no-op.

### Steps

- [ ] Add `WatcherReducerTests.testGenerationReplacementPreservesOnlyLatestDigestByName`.
  Seed every `FileState`, an active episode, and a digest entry; replace the
  generation; assert a fresh file table/ordering value, the supplied new token, and
  unchanged digest table.

- [ ] Run
  `swift test --filter WatcherReducerTests/testGenerationReplacementPreservesOnlyLatestDigestByName`.
  Expected: compile failure because the reducer types do not exist.

- [ ] Add the minimal outer/generation/state/settlement types and
  `.replaceGeneration` handling. Do not add filesystem calls.

- [ ] Run the same test. Expected: pass.

- [ ] Add table-driven absence tests covering all six states. Assert pending
  states are removed and all terminal states remain byte-for-byte unchanged.

- [ ] Run `swift test --filter WatcherReducerTests/testAbsenceSemantics`.
  Expected: fail until `.observe` handles complete-batch absence.

- [ ] Implement absence reduction and derived helpers for emitted names and
  numeric high-water. The high-water helper must inspect only
  `.settled(.emittedNow)` numbered entries.

- [ ] Add tests showing both settlement variants retain identity+digest and
  produce an identity fast-path read request, while `.classicMutable` produces
  a digest request even when settled.

- [ ] Add the classic pair:
  `testClassicTransientDigestReturnsToLastEmissionWithoutYield` and
  `testClassicEmittedBThenAReearnsGateAndYieldsA`.

- [ ] Implement stat stability, digest stability, dedup settlement, and classic
  back-transitions in the reducer. Preserve the existing two-observation timing
  and digest monotonicity rules; consume pending evidence on settlement.

- [ ] Add `testStaleGenerationEmissionResultCannotSettleOrChangeDigest` and a
  current-generation success sibling. Implement generation validation at the
  result-command boundary.

- [ ] Run `swift test --filter WatcherReducerTests`. Expected: all Task 1 tests
  pass.

- [ ] Run `rg -n "FileManager|\\bopen\\(|\\bstat\\(|\\bread\\(" Sources/LiveAstroCore/Watch/WatcherFileState.swift`.
  Expected: no matches.

- [ ] Commit:
  `git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift && git commit -m "refactor: introduce pure watcher state reducer"`.

---

## Task 2: Move revision ordering and blocking into the reducer

**Files:**

- Modify: `Sources/LiveAstroCore/Watch/WatcherFileState.swift`
- Modify: `Tests/LiveAstroCoreTests/WatcherReducerTests.swift`
- Create: `Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift`

### Required reducer behavior

The reducer first classifies the complete observation batch, settles
latest-digest duplicates, derives the numeric high-water, and only then derives
the head blocker and victims. A duplicate settlement is terminal before victim
accounting. The sole `BlockingEpisode` carries the clock. When its defining
predicate becomes false, clear it immediately. If the same filename later
becomes a blocker again, create a fresh episode at the current monotonic time.

### Steps

- [ ] Add the exact review-12 P1-1 regression: retain an old-generation digest
  for `_00002`, replace the generation, present failing `_00001` plus changed
  `_00002`, and assert `_00001` owns an active deadline, `_00002` is held, and
  the output cannot become `[3, 2]` after write-off.

- [ ] Run
  `swift test --filter WatcherReducerTests/testRetainedDigestIsNeverGenerationOrderingEvidence`.
  Expected: fail because blocker derivation is not implemented.

- [ ] Implement numeric revision parsing/comparison as one shared helper for
  classification, sorting, high-water, and mark-drop. Port semantics from
  `StackFileWatcher.revisionSuffix`, `numericCompare`, and `orderedBefore`
  without duplicating the parser.

- [ ] Implement derived high-water, mark-drop, head-of-line holdback, and
  ordered emission intents. Never advance the mark for duplicate, written-off,
  or dropped states.

- [ ] Add the review-12 P1-2 role-round-trip regression: a name becomes a
  blocker, becomes a victim, then becomes a blocker again; assert its second
  episode starts at the second transition and cannot inherit the first clock.

- [ ] Add deterministic victim lifecycle tests: disappearance destroys the
  episode while the blocker remains; reappearance creates a fresh episode;
  duplicate settlement while held removes that victim; a lone blocker never
  owns an episode.

- [ ] Port the current budget formula, convergence-grace extension, ceiling,
  churn, write-off, and log-duration calculations into reducer helpers. Keep
  the existing strings so integration tests remain meaningful.

- [ ] Run `swift test --filter WatcherReducerTests`. Expected: pass.

- [ ] Add deterministic property tests using a fixed-seed generator (minimum
  1,000 transitions per property):
  1. derived high-water is monotone within a generation;
  2. no numbered revision at/below the mark produces an emission intent;
  3. `activeBlocker != nil` iff the approved blocker/victim predicate holds;
  4. changing only the outer digest table cannot change blocker accounting or
     the derived mark;
  5. role round-trips never inherit episode clocks;
  6. absence never changes terminal state within a generation.

- [ ] Run `swift test --filter WatcherReducerPropertyTests`. Expected: all
  properties pass and reproduce deterministically on failure.

- [ ] Commit:
  `git add Sources/LiveAstroCore/Watch/WatcherFileState.swift Tests/LiveAstroCoreTests/WatcherReducerTests.swift Tests/LiveAstroCoreTests/WatcherReducerPropertyTests.swift && git commit -m "refactor: reduce watcher revision ordering as one state machine"`.

---

## Task 3: Port `StackFileWatcher.scan()` to observe → reduce → effect

**Files:**

- Modify: `Sources/LiveAstroCore/Watch/StackFileWatcher.swift`
- Modify only if harness access requires it:
  `Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`

### Integration boundary

`scan()` retains responsibility for filesystem effects only:

1. verify/reopen the watched folder and allocate a new generation token on
   disappearance/return or identity replacement;
2. enumerate and sort entries through the pinned directory descriptor;
3. ask the reducer's state for the read plan;
4. perform existing stat/header/digest reads and produce a complete
   `ObservationBatch` without mutating semantic state;
5. submit one `.observe` command;
6. execute returned effects in order;
7. revalidate folder identity immediately before each yield, then submit
   `.emissionFinished` with the original intent.

Mechanical counters such as `_digestComputations` may remain driver-owned;
they are observability, not semantic evidence.

### Steps

- [ ] Add or isolate an integration pin proving a folder replacement after
  observation but before emission rejects the old intent, starts a fresh
  generation, rehashes the new file once, and retains only latest-digest dedup.

- [ ] Run its exact test filter. Expected: fail against the current scan-loop
  mutation boundary.

- [ ] Add one `WatcherReducer` property to `StackFileWatcher`. Rename the
  surviving digest field at the boundary or move it directly into
  `WatcherState`; there must be one owner, not mirrored storage.

- [ ] Extract observation construction from `scan()` using the current
  descriptor-based operations. Do not change their ordering or error/log
  semantics. Every enumerated tracked filename must produce one observation;
  tracked pending names missing from enumeration must receive `.absent` in the
  same complete batch.

- [ ] Route generation changes through one whole-value replacement command.
  Delete coordinated generation-local clearing from `scan()` and
  `handleFolderReplaced()`.

- [ ] Execute reducer logs and emission intents in returned order. Keep the
  current pre-yield directory identity check and consumer-side identity/digest
  contract. Send success/failure back through `.emissionFinished`; never write
  settlement or digest state directly in the driver.

- [ ] Delete the superseded semantic collections and their mutation helpers:
  `lastSeenStat`, `pendingContent`, `lastEmittedIdentity`,
  `emittedRevisionHighWater`, `outOfOrderDropLogged`, `blockTracks`, and
  `writtenOffRevisions`. Remove or move parser/order helpers only after all
  callers use the reducer's anchored implementation.

- [ ] Run `swift test --filter WatcherReducerTests` and
  `swift test --filter WatcherReducerPropertyTests`. Expected: pass.

- [ ] Run `swift test --filter StackFileWatcherTests`. Expected: all existing
  assertions pass unchanged, including lone-period clock, honest write-off
  duration, oscillator/ceiling, mark-drop, long-pause boundary, generation
  cache reset, and digest cost-model tests.

- [ ] Run `swift test --filter FaultMatrixFileTests`. Expected: pass.

- [ ] Inspect `git diff -- Tests/LiveAstroCoreTests/StackFileWatcherTests.swift`.
  Expected: empty, or mechanical harness access only with no expectation edits.

- [ ] Commit:
  `git add Sources/LiveAstroCore/Watch/StackFileWatcher.swift Tests/LiveAstroCoreTests/StackFileWatcherTests.swift && git commit -m "refactor: drive folder scans through watcher reducer"`.

---

## Task 4: Phase-1 verification and review handoff

**Files:**

- Modify only for documentation discovered during verification:
  `docs/superpowers/specs/2026-07-16-watcher-state-model-and-reseed-contract-design.md`
- Do not begin phase 2.

### Steps

- [ ] Verify the old parallel semantic storage is gone:

  ```bash
  rg -n "lastSeenStat|pendingContent|lastEmittedIdentity|emittedRevisionHighWater|outOfOrderDropLogged|blockTracks|writtenOffRevisions" Sources/LiveAstroCore/Watch
  ```

  Expected: no live declarations or mutations; comments referring to removed
  implementation names should also be rewritten in state-machine terms.

- [ ] Run `git diff --check`. Expected: no whitespace errors.

- [ ] Run `swift test`. Expected: full suite green with zero failures.

- [ ] Run `swift build -c release`. Expected: successful release build with no
  warnings.

- [ ] Run a warning-specific test-build gate and retain the output in the
  implementation report:
  `swift test 2>&1 | tee /tmp/liveastro-phase1-test.log` followed by
  `rg -n "warning:" /tmp/liveastro-phase1-test.log`.
  Expected: no warning matches.

- [ ] Review the final diff against every §2 requirement and explicitly report:
  state ownership, generation replacement, derived ordering evidence, episode
  iff invariant, absence semantics, settlement payloads/fast paths, classic
  A/B/A behavior, and stale effect rejection.

- [ ] Request a code review of phase 1. Fix only phase-1 defects red-first; do
  not broaden into the reseed/master or review-12 P2 waves.

- [ ] Commit any review-only corrections separately, then report the exact
  commit range and verification counts. Leave phase 2 parked pending the
  approved sequence.

## Execution handoff

Execute this plan task-by-task with `superpowers:subagent-driven-development`
in the existing isolated branch. Because all tasks touch the same reducer or
scan loop, run them sequentially; do not dispatch parallel implementers and do
not overlap SwiftPM. Use `superpowers:test-driven-development` for every
behavioral change and `superpowers:verification-before-completion` before any
claim that phase 1 is complete.
