# Fault Matrix — LiveAstro Studio

Living document (spec `docs/superpowers/specs/2026-07-15-fault-injection-design.md`, §"The Fault Matrix").
Updated in the same commit as its tests; a stale matrix is a review defect.

## Invariant (governs every cell)

> A boundary failure may lose or reject one frame; it must never invalidate, silently corrupt, or
> prevent recovery of the session. **Every degradation must appear honestly in the log.**

## Cell legend

- **TEST(name)** — a named test exercises this cell against the real filesystem.
- **N/A(reason)** — the fault cannot occur at this boundary (one-line reason).
- **PROXY(label)** — a test exists but approximates a fault it cannot induce directly
  (e.g. read-only dir ≈ ENOSPC/EIO; the real errno is not claimed).

All Task-2 tests live in `Tests/LiveAstroCoreTests/FaultMatrixFileTests.swift` unless noted.
Chmod-based cells write-probe first and `XCTSkip` with a diagnostic on a privileged runner
(chmod ineffective) rather than passing vacuously.

## Columns (faults)

mid-write/growing · truncated · deleted-mid-run · directory-removed · read-only destination ·
invalid replacement target · slow/hung consumer · crash-terminated (helper) · restart-recovery.

## Rows — File boundaries (Task 2)

| Boundary | mid-write / growing | truncated | deleted-mid-run | directory-removed | read-only destination | invalid replacement target | slow/hung consumer | crash-terminated | restart-recovery |
|---|---|---|---|---|---|---|---|---|---|
| **FITS ingest** (`FITSReader.read`) | TEST(`testFITS_midWrite_readerRejectsHeaderOnlyAcceptsComplete`) — header-only intermediate throws `truncatedData`; complete file parses once | TEST(`testFITS_truncated_readerThrowsNoPartialImage`) — pixels cut at 60% → throws `truncatedData`, no partial image; TEST(`testFITS_truncated_watcherRejectsThenAcceptsComplete`) — via watcher: rejected then complete write ingests | N/A — the reader is a pure `Data`→image function; a file deleted before read simply never reaches `read`. Deletion-during-read is covered at the watcher boundary (`testWatcher_deletedMidRun_noCrashNextFileFine`) | N/A — reader takes bytes, not a directory; the containing-dir case is the watcher's (`testWatcher_dirRemoved_survivesNoCrash`) | N/A — `read` never writes; there is no destination at this boundary | TEST(`testFITS_invalidReplacement_directoryNamedFit`) — path `x.fit` is a directory: `Data(contentsOf:)` throws (no bytes); watcher skips it, a later real file still ingests | N/A — synchronous pure function, no consumer callback | N/A — reader is a reader; crash-mid-write applies to writers (T3 `faulthelper`) | N/A — no persistent reader state to recover |
| **FrameRelay** | TEST(`testRelay_midWriteGrowing_neverPublishedUntilStable_noTempLitter`) — grown across ticks, never published until stable; temp never visible under glob | TEST(`testRelay_truncatedDest_healedOnceWithLog`) — pre-existing truncated dest healed exactly once, one `relay healed` log, then skipped | TEST(`testRelay_deletedMidRun_noPublishNoCrashPendingCleared`) — source deleted between ticks: no publish, no crash, pending entry cleared (recreate re-primes) | TEST(`testRelay_sourceDirRemoved_logsAndSurvivesThenResumes`) — source dir removed: logs `source unreachable`, keeps ticking, resumes on restore | PROXY(read-only dir ≈ ENOSPC/EIO) — `testRelay_readOnlyDest_copyFailsLoggedRetriedNoLitter` — staged copy fails, logged `retry next poll`, no temp litter, relays after restore | N/A — relay copies real files; "invalid replacement" (dir/symlink where a file is expected) is a reader/pruner concern, not the relay's copy path | N/A — relay has no consumer callback; it is a producer. Downstream slow-consumer is the pipeline row (T3) | PROXY→T3 — relay crash-mid-copy is covered in T3 via `faulthelper` (partial `.relaytmp` aftermath) per spec §Components/T3 | PROXY→T3 — restart against relay artifacts is T3 |
| **RelayPruner** | N/A — pruner acts on whole dated session dirs at rest; there is no growing/partial file to observe | N/A — pruner never reads file contents; a truncated file inside a session is irrelevant to age-based removal | N/A — a session dir deleted before prune simply isn't listed; `contentsOfDirectory` failure returns `[]` (best-effort) | N/A — the ROOT missing → `contentsOfDirectory` fails → returns `[]` (guarded, non-throwing); no separate test needed | PROXY(read-only dir ≈ undeletable/ENOSPC) — `testPruner_readOnlySessionDir_skippedBestEffortOthersRemoved` — read-only old session skipped best-effort (no throw), deletable sibling still removed | TEST(`testPruner_danglingSymlinkEntry_skippedUntouched`) — dangling symlink with a dated name: `isDirectory` false → skipped, left untouched; real old dir still pruned | N/A — pruner is synchronous, no consumer | N/A — pruner is a periodic sweep, not a writer; no crash-mid-write artifact | N/A — pruner is idempotent and stateless; nothing to recover |
| **StackFileWatcher** | TEST(`testWatcher_midWriteGrowing_notEmittedUntilStable`) — preallocated + mtime-bumping file not emitted until stable, then exactly once | PROXY→existing — truncated FITS rejection is covered by the FITS row's `testFITS_truncated_watcherRejectsThenAcceptsComplete` and existing `StackFileWatcherTests.testIgnoresPartialFITSUntilComplete` (size < `minimumFileSize` gate) | TEST(`testWatcher_deletedMidRun_noCrashNextFileFine`) — file deleted after emit: no crash, no re-emit, a new file still ingests | TEST(`testWatcher_dirRemoved_logsOnceAndResumesOnRecreate`, `testWatcher_stopAfterDirRemoved_noCrash`) — folder removed mid-run: logs exactly once ("watched folder disappeared"), no spurious emit, no crash; folder recreated → same live watcher resumes (re-arms DispatchSource fd) and ingests a new FITS; stop() during missing window is idempotent. Full invariant including clause 6 (honest log) now met. FOUND-BUG #1 fixed. | N/A — the watcher only reads the watched folder; it never writes a destination | N/A(covered by FITS row) — a directory named `*.fit` in the watched folder is exercised in `testFITS_invalidReplacement_directoryNamedFit` (watcher skips, no emit) | N/A(here) — the slow/hung consumer is a downstream-of-watcher pipeline concern (drain-timeout), T3 row | N/A — watcher is a reader; crash-mid-write applies to the writer feeding it | N/A(here) — watcher holds only in-memory stat/digest state; recovery is a fresh `start()` (see dir-removed) |

### Notes / justification for proxies and gaps

- **read-only ≈ ENOSPC/EIO**: chmod is a *proxy* for a full/failing destination. The real errno is
  not claimed. The future path to genuine ENOSPC/EIO is the pre-approved injectable manifest writer
  (spec §Seams), added only if a T3/T4 cell proves undrivable without it. Not needed for Task 2.
- **FIXED — StackFileWatcher directory-removed** (FOUND-BUG #1, resolved): `StackFileWatcher` now
  has a `public var onLog: ((String) -> Void)?` seam (mirrors `FrameRelay.onLog`) and a
  `folderMissing` flag so the disappearance is logged exactly once per event (not every tick).
  On folder return, the stale `O_EVTONLY` fd / DispatchSource is cancelled and a new one is armed
  via a shared `armSource()` private method (called from both `start()` and `scan()`), so the live
  watcher resumes without needing a new instance. `onLog` is wired in `SessionPipeline` (watcher
  mode) and forwarded through `FolderFrameSource` (native-stack live mode). Full invariant including
  clause 6 now met; cell upgraded from PROXY(partial) to TEST.

## Rows — Lifecycle boundaries (Task 3)

All Task-3 tests live in `Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift`. Crash and
restart-recovery cells drive the REAL `faulthelper` executable via `CrashArtifactBuilder`
(a genuine SIGKILL mid-state, not an in-process release). Every cell that leaves a session on disk
ends with `assertSessionOracle`. Chmod cells write-probe first and `XCTSkip` with a diagnostic on a
privileged runner.

| Boundary | mid-write / growing | truncated | deleted-mid-run | directory-removed | read-only destination | invalid replacement target | slow/hung consumer | crash-terminated | restart-recovery |
|---|---|---|---|---|---|---|---|---|---|
| **SessionManager** (`startSession`/`recordSnapshot`/`endSession`) | N/A — the manifest write is atomic (temp+rename via `Data(.atomic)`); there is no observable growing/partial manifest. Torn-write survival is the crash-terminated cell (`manifest-midwrite`) | N/A — a truncated manifest is a *reader-side* corruption; the writer never produces one (atomic). Oracle clause 1 already fails a torn manifest (proven by `FaultKitTests.testOracleHasTeeth`) | TEST(`testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess`) — session dir removed mid-session: the next `recordSnapshot` throws honestly, `acceptedCount` never inflates (write-then-commit); no false success | TEST(`testSessionManager_dirRemovedMidSession_...`) — same cell (dir removal *is* the directory-removed fault at this boundary) | PROXY(read-only dir ≈ ENOSPC/EIO) — `testSessionManager_readOnlyMidSession_recordThrowsStateUnchangedThenHeals` — read-only session dir → atomic write fails → `recordSnapshot` throws, in-memory state unchanged; restore → later snapshots accepted; oracle counts truthful | N/A(covered by SnapshotRecorder row) — a `manifest.json` replaced by a dir/symlink is a reader corruption caught by oracle clause 1; the *snapshot-path* invalid-target case is exercised at the recorder | N/A — SessionManager is synchronous; it has no consumer callback (the slow-consumer fault is the pipeline row) | TEST(`testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean`) — `faulthelper session-midframes` SIGKILLed with 3 durable snapshots: manifest parses, 3 snapshots intact, `end_time` nil (truthfully still running) | TEST(`testCrash_sessionMidframes_...`) — a fresh `SessionManager` on the same root starts a NEW session in a sibling dir cleanly (killed session recoverable + does not block a fresh start) |
| **SnapshotRecorder** (`save`) | N/A — `CGImageDestinationFinalize` writes the PNG in one shot to its final URL; there is no partial-PNG intermediate the manifest ever references (the record is returned only after finalize succeeds) | N/A — same: a save either finalizes a complete PNG or throws `encodeFailed`; a truncated PNG is never committed to the manifest | TEST(`testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — `snapshots/` removed: `save` throws, the pipeline logs a dropped/skipped frame, the manifest never lists the unsaved snapshot, the session continues (later save accepted) | TEST(`testSnapshotRecorder_dirRemoved_...`) — same cell (removing `snapshots/` *is* the directory-removed fault at the recorder) | PROXY(read-only ≈ ENOSPC) — covered transitively by `testSessionManager_readOnly...` (the recorder writes into the same session dir; a read-only dir fails the PNG write with `encodeFailed`, logged as a dropped frame, manifest omits it) | TEST(`testSnapshotRecorder_dirRemoved_...`) — a removed `snapshots/` is the invalid-target for the PNG path; `save` throws cleanly and the manifest omits the frame (same test) | N/A — the recorder is synchronous with no consumer callback | N/A — the recorder holds no persistent state; a crash mid-save leaves at most an unreferenced partial PNG the manifest never lists (recorder returns the record only after finalize) | N/A — nothing to recover: the manifest is the source of truth and never references an unsaved PNG |
| **SessionPipeline** (`start`/`end`) | TEST(`testPipelineMidSession_frameFloodOneHostile_onlyBadRejectedBothValidsKept`) — mixed stream (valid · hostile · valid): exactly the hostile frame is rejected+logged, both valids accepted; invariant "lose a frame, never the session" holds; oracle lists exactly 2 | N/A(covered by FITS/watcher rows) — a truncated *input* is rejected at ingest (T2 FITS/watcher cells); the pipeline's own state has no truncatable artifact | N/A(covered by SessionManager row) — a deleted session dir surfaces through `SessionManager.recordSnapshot` (SessionManager dir-removed cell); the pipeline catches and logs it as a skipped frame | N/A(covered by SessionManager row) — same: directory removal is owned by SessionManager; the pipeline's try/catch logs it | PROXY(read-only ≈ ENOSPC) — covered by the SessionManager read-only cell (the pipeline delegates persistence to SessionManager; a failed record is caught and logged as "Skipped frame") | N/A(covered by recorder row) — an invalid snapshot target is the recorder's cell; the pipeline logs the thrown error | TEST(`testPipelineEnd_wedgedConsumer_throwsShutdownTimeoutNoFinalization`) — `SlowConsumer` wedges the consume task inside `onUpdate`; `end()` throws `shutdownTimeout`, the last durable manifest is intact, NO `master.fit` is written (no finalization of a racing stack); oracle clause 5 honest | N/A — the pipeline is glue over SessionManager (crash artifacts are the SessionManager/relay cells); a crash mid-pipeline leaves a SessionManager artifact, already covered | TEST(`testPipelineStart_sourceThrows_rollsBackRetrySucceedsNoOrphanDir`) — `start()` with a throwing source rolls back the just-created session (no orphan running dir on disk); a retry succeeds (not `alreadyRunning`); oracle on the retried session |
| **BatchImporter** (import path) | N/A — the importer produces no persistent artifact; commits flow to SessionManager (whose atomic write is the SessionManager row) | N/A — no truncatable importer artifact; a truncated *sub* is rejected at ingest (FITS row) | N/A — a sub deleted before read never reaches a worker; the importer accounts for every frame it *does* read (existing `BatchImporterTests.testAllSubsAccountedFor`) | N/A — the importer writes no directory; persistence is SessionManager's | N/A — the importer never writes a destination (workers register/warp in memory; commit is SessionManager's) | N/A — no replacement target at this boundary | TEST(`testBatchImporter_cancelMidImport_drainsInFlightCountTruthful`) — `cancelImport()` (via `isCancelled`) mid-import: in-flight work drains, the committed count equals `engine.acceptedCount` (truthful, no phantom/over-count), oracle passes on the partial-but-honest session | N/A — the importer is transient in-process work; a crash leaves a SessionManager artifact (that row), not an importer one | N/A — the importer is stateless across runs; recovery is a fresh import; the durable state is SessionManager's |

### Crash / relay recovery (faulthelper, all rows)

| Scenario | Test | Assertion |
|---|---|---|
| `session-midframes` | TEST(`testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean`) | SIGKILL with 3 durable snapshots → manifest parses, 3 snapshots intact + readable, `end_time` nil (running is truthful); a fresh manager starts a sibling session cleanly |
| `manifest-midwrite` | TEST(`testCrash_manifestMidwrite_manifestEitherCompleteNeverTorn`) | SIGKILL mid-rewrite → manifest is EITHER the previous complete version OR the new complete version (atomic write) — never torn; oracle clause 1 (parses) is the teeth |
| `relay-midcopy` | TEST(`testCrash_relayMidcopy_noGlobVisiblePartialFreshRelayHeals`) | SIGKILL mid-copy → dst has NO glob-visible partial (staged to a hidden `.<name>.relaytmp` / itemReplacement dir, only atomically renamed into place); a fresh relay over the same dirs completes the copy (heals), healed size == source size |

### Notes / justification — Task 3

- **Zero FOUND-BUGs in T3.** Every lifecycle cell is GREEN. This is the expected outcome: the
  external-review fix wave (merged ea2a227) already closed these sharp edges (write-then-commit
  persistence, startup rollback, drain timeout, atomic manifest write, relay staged-copy). Task 3
  *systematizes* those regressions into a matrix and the crash-terminated/restart-recovery cells
  the fix wave never had — proving the invariant against a REAL killed process, not just in-process
  objects. (T2 already found + fixed one real bug this way — FOUND-BUG #1, the watcher.)
- **read-only ≈ ENOSPC/EIO** (SessionManager/SnapshotRecorder): chmod is a proxy for a full/failing
  volume. The real errno is not claimed. The pre-approved injectable manifest writer (spec §Seams)
  is the future path to genuine ENOSPC/EIO — NOT added here: no T3 cell proved undrivable without it
  (the read-only dir drives the atomic-write failure faithfully). YAGNI holds.
- **No production-code changes in T3.** No seam was required; every cell was drivable with FaultKit
  against the real filesystem.
- **Crash cells use a genuine SIGKILL.** `CrashArtifactBuilder` runs `faulthelper` to a coordinated
  readiness flag, then `kill(pid, SIGKILL)` — the aftermath is a real killed-mid-state directory,
  satisfying the spec's "terminated helper process, not merely objects released in-process" rule.
