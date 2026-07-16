# Fault Matrix — LiveAstro Studio

Living document (spec `docs/history/specs/2026-07-15-fault-injection-design.md`, §"The Fault Matrix").
Updated in the same commit as its tests; a stale matrix is a review defect.

**Seams: BOTH pre-approved seams are now in use, each required by one crash cell.** The
`FrameRelay.onPrePublish` sync hook (spec §Seams) is required by the `relay-midcopy` cell — the ONLY
way to land a SIGKILL genuinely between the staged copy and the atomic publish. The injectable
`SessionManager.manifestWriter` (spec §Seams) is required by the `manifest-midwrite` cell — the ONLY
way to guarantee the SIGKILL lands within an open manifest-write transaction (justification notes
below). Both are production no-ops: nil by default, with the built-in behavior unchanged.

## How to add a row/cell

1. Add the row to the table below; fill every column (TEST / N/A / PROXY — no blank cells).
2. For TEST: write the test first (TDD), then update the cell with the exact method name.
3. For N/A: supply a one-line reason; if referencing another row, verify that row's cell is TEST.
4. For PROXY: name what is being approximated (e.g. read-only dir ≈ ENOSPC/EIO).
5. Add the commit that adds the test and the matrix update together (stale matrix = review defect).

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
| **FITS ingest** (`FITSReader.read`) | TEST(`testFITS_midWrite_readerRejectsHeaderOnlyAcceptsComplete`) — header-only intermediate throws `truncatedData`; complete file parses once | TEST(`testFITS_truncated_readerThrowsNoPartialImage`) — pixels cut at 60% → throws `truncatedData`, no partial image; TEST(`testFITS_truncated_watcherRejectsThenAcceptsComplete`) — via watcher: rejected then complete write ingests | N/A — the reader is a pure `Data`→image function; a file deleted before read simply never reaches `read`. Deletion-during-read is covered at the watcher boundary (`testWatcher_deletedMidRun_noCrashNextFileFine`) | N/A — reader takes bytes, not a directory; the containing-dir case is the watcher's (`testWatcher_dirRemoved_logsOnceAndResumesOnRecreate`) | N/A — `read` never writes; there is no destination at this boundary | TEST(`testFITS_invalidReplacement_directoryNamedFit`) — path `x.fit` is a directory: `Data(contentsOf:)` throws (no bytes); watcher skips it, a later real file still ingests | N/A — synchronous pure function, no consumer callback | N/A — reader is a reader; crash-mid-write applies to writers (T3 `faulthelper`) | N/A — no persistent reader state to recover |
| **FrameRelay** | TEST(`testRelay_midWriteGrowing_neverPublishedUntilStable_noTempLitter`) — grown across ticks, never published until stable; temp never visible under glob | TEST(`testRelay_truncatedDest_healedOnceWithLog`) — pre-existing truncated dest healed exactly once, one `relay healed` log, then skipped | TEST(`testRelay_deletedMidRun_noPublishNoCrashPendingCleared`) — source deleted between ticks: no publish, no crash, pending entry cleared (recreate re-primes) | TEST(`testRelay_sourceDirRemoved_logsAndSurvivesThenResumes`) — source dir removed: logs `source unreachable`, keeps ticking, resumes on restore | PROXY(read-only dir ≈ ENOSPC/EIO) — `testRelay_readOnlyDest_copyFailsLoggedRetriedNoLitter` — staged copy fails, logged `retry next poll`, no temp litter, relays after restore | N/A — relay copies real files; "invalid replacement" (dir/symlink where a file is expected) is a reader/pruner concern, not the relay's copy path | N/A — relay has no consumer callback; it is a producer. Downstream slow-consumer is the pipeline row (T3) | PROXY→T3(`testCrash_relayMidcopy_noGlobVisiblePartialFreshRelayHeals`) — relay crash-mid-copy covered in T3 via `faulthelper` (partial `.relaytmp` aftermath): no glob-visible partial left in dst after SIGKILL | PROXY→T3(`testCrash_relayMidcopy_noGlobVisiblePartialFreshRelayHeals`) — restart against relay artifacts is T3: a fresh relay over the same src/dst heals (completes the copy, healed size == source size) |
| **RelayPruner** | N/A — pruner acts on whole dated session dirs at rest; there is no growing/partial file to observe | N/A — pruner never reads file contents; a truncated file inside a session is irrelevant to age-based removal | N/A — a session dir deleted before prune simply isn't listed; `contentsOfDirectory` failure returns `[]` (best-effort) | N/A — the ROOT missing → `contentsOfDirectory` fails → returns `[]` (guarded, non-throwing); no separate test needed | PROXY(read-only dir ≈ undeletable/ENOSPC) — `testPruner_readOnlySessionDir_skippedBestEffortOthersRemoved` — read-only old session skipped best-effort (no throw), deletable sibling still removed | TEST(`testPruner_danglingSymlinkEntry_skippedUntouched`) — dangling symlink with a dated name: `isDirectory` false → skipped, left untouched; real old dir still pruned | N/A — pruner is synchronous, no consumer | N/A — pruner is a periodic sweep, not a writer; no crash-mid-write artifact | N/A — pruner is idempotent and stateless; nothing to recover |
| **StackFileWatcher** | TEST(`testWatcher_midWriteGrowing_notEmittedUntilStable`) — preallocated + mtime-bumping file not emitted until stable, then exactly once | PROXY→existing — truncated FITS rejection is covered by the FITS row's `testFITS_truncated_watcherRejectsThenAcceptsComplete` and existing `StackFileWatcherTests.testIgnoresPartialFITSUntilComplete` (size < `minimumFileSize` gate) | TEST(`testWatcher_deletedMidRun_noCrashNextFileFine`) — file deleted after emit: no crash, no re-emit, a new file still ingests | TEST(`testWatcher_dirRemoved_logsOnceAndResumesOnRecreate`, `testWatcher_stopAfterDirRemoved_noCrash`) — folder removed mid-run: logs exactly once ("watched folder disappeared"), no spurious emit, no crash; folder recreated → same live watcher resumes (re-arms DispatchSource fd) and ingests a new FITS; stop() during missing window is idempotent. Full invariant including clause 6 (honest log) now met. FOUND-BUG #1 fixed. TEST(`testWatcher_folderAtomicallyReplaced_reArmsAndReEarnsStability`) — folder ATOMICALLY swapped (rename(2)-family `RENAME_SWAP`, no missing interval, review3 P1): detected via (st_dev, st_ino) identity mismatch against the armed fd, logged ("watched folder was replaced"), stale source cancelled and re-armed on the new inode BEFORE claiming recovery, pending stability cleared (same-name/size/mtime file re-earns stability across a tick; emitted digests retained for dedup), a genuinely new file in the swapped-in dir ingests. Review4 closes the residual MID-SCAN window structurally: `scan()` enumerates and stats through the ARMED fd (`openat(fd, ".")` → `fdopendir`/`readdir`, `fstatat`), never by path, so a swap landing between the identity check and the enumeration is harmless BY CONSTRUCTION — the fd pins the old inode and the pass observes only old-directory contents; the next scan's identity check detects the swap. Pinned deterministically (no timing) by TEST(`testEnumerateDirectory_pinnedFDSeesOldContentsAcrossAtomicSwap`). Content reads (FITS header/digest) remain path-based, protected by the stability+digest gates | N/A — the watcher only reads the watched folder; it never writes a destination | TEST(`testWatcher_regularFileAtFolderPath_notMistakenForRecovery`) — a regular FILE at the exact watched-folder path (review3 P2): NOT recovery — `open(O_EVTONLY)` would succeed on it, but presence now requires an actual directory; no "resuming" claim while the impostor sits there (logged once, no per-tick spam), genuine directory recreation resumes and a new file ingests. A directory named `*.fit` INSIDE the folder remains covered by `testFITS_invalidReplacement_directoryNamedFit` (watcher skips, no emit) | N/A(here) — the slow/hung consumer is a downstream-of-watcher pipeline concern (drain-timeout), T3 row | N/A — watcher is a reader; crash-mid-write applies to the writer feeding it | N/A(here) — watcher holds only in-memory stat/digest state; recovery is a fresh `start()` (see dir-removed) |

### Notes / justification for proxies and gaps

- **read-only ≈ ENOSPC/EIO**: chmod is a *proxy* for a full/failing destination. The real errno is
  not claimed. The injectable manifest writer (spec §Seams) — since implemented at review2 for the
  `manifest-midwrite` crash cell — is the future path to genuine ENOSPC/EIO injection, which no cell
  claims yet. Not needed for Task 2.
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
| **SessionManager** (`startSession`/`recordSnapshot`/`endSession`) | N/A — the manifest write is atomic (temp+rename via `Data(.atomic)`); there is no observable growing/partial manifest. Torn-write survival is the crash-terminated cell (`manifest-midwrite`) | N/A — a truncated manifest is a *reader-side* corruption; the writer never produces one (atomic). Oracle clause 1 already fails a torn manifest (proven by `FaultKitTests.testOracleHasTeeth`) | TEST(`testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess`) — session dir removed mid-session: the next `recordSnapshot` throws honestly, `acceptedCount` never inflates (write-then-commit); no false success | TEST(`testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess`) — same test (dir removal *is* the directory-removed fault at this boundary: the deleted-mid-run and directory-removed columns converge here) | PROXY(read-only dir ≈ ENOSPC/EIO) — `testSessionManager_readOnlyMidSession_recordThrowsStateUnchangedThenHeals` — read-only session dir → atomic write fails → `recordSnapshot` throws, in-memory state unchanged; restore → later snapshots accepted; oracle counts truthful | N/A(covered by SnapshotRecorder row `testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — a `manifest.json` replaced by a dir/symlink is a reader corruption caught by oracle clause 1; the *snapshot-path* invalid-target case is exercised at the recorder | N/A — SessionManager is synchronous; it has no consumer callback (the slow-consumer fault is the pipeline row) | TEST(`testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean`) — `faulthelper session-midframes` SIGKILLed with 3 durable snapshots: manifest parses, 3 snapshots intact, `end_time` nil (truthfully still running) | TEST(`testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean`) — same test covers restart-recovery: a fresh `SessionManager` on the same root starts a NEW session in a sibling dir cleanly (killed session recoverable + does not block a fresh start) |
| **SnapshotRecorder** (`save`) | N/A — `CGImageDestinationFinalize` writes the PNG in one shot to its final URL; there is no partial-PNG intermediate the manifest ever references (the record is returned only after finalize succeeds) | N/A — same: a save either finalizes a complete PNG or throws `encodeFailed`; a truncated PNG is never committed to the manifest | TEST(`testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — `snapshots/` removed: `save` throws, the pipeline logs a dropped/skipped frame, the manifest never lists the unsaved snapshot, the session continues (later save accepted) | TEST(`testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — same test (removing `snapshots/` *is* the directory-removed fault at the recorder: deleted-mid-run and directory-removed converge here) | PROXY(read-only ≈ ENOSPC) — covered transitively by `testSessionManager_readOnlyMidSession_recordThrowsStateUnchangedThenHeals` (the recorder writes into the same session dir; a read-only dir fails the PNG write with `encodeFailed`, logged as a dropped frame, manifest omits it) | TEST(`testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — a removed `snapshots/` is the invalid-target for the PNG path; `save` throws cleanly and the manifest omits the frame (same test as dir-removed) | N/A — the recorder is synchronous with no consumer callback | N/A — the recorder holds no persistent state; a crash mid-save leaves at most an unreferenced partial PNG the manifest never lists (recorder returns the record only after finalize) | N/A — nothing to recover: the manifest is the source of truth and never references an unsaved PNG |
| **SessionPipeline** (`start`/`end`) | TEST(`testPipelineMidSession_frameFloodOneHostile_onlyBadRejectedBothValidsKept`) — mixed stream (valid · hostile · valid): exactly the hostile frame is rejected+logged, both valids accepted; invariant "lose a frame, never the session" holds; oracle lists exactly 2 | N/A(covered by FITS row `testFITS_truncated_readerThrowsNoPartialImage` and watcher row `testWatcher_midWriteGrowing_notEmittedUntilStable`) — a truncated *input* is rejected at ingest (T2 FITS/watcher cells); the pipeline's own state has no truncatable artifact | N/A(covered by SessionManager row `testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess`) — a deleted session dir surfaces through `SessionManager.recordSnapshot`; the pipeline catches and logs it as a skipped frame | N/A(covered by SessionManager row `testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess`) — same: directory removal is owned by SessionManager; the pipeline's try/catch logs it | PROXY(read-only ≈ ENOSPC) — covered by `testSessionManager_readOnlyMidSession_recordThrowsStateUnchangedThenHeals` (the pipeline delegates persistence to SessionManager; a failed record is caught and logged as "Skipped frame") | N/A(covered by recorder row `testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt`) — an invalid snapshot target is the recorder's cell; the pipeline logs the thrown error | TEST(`testPipelineEnd_wedgedConsumer_throwsShutdownTimeoutNoFinalization`) — `SlowConsumer` wedges the consume task inside `onUpdate`; `end()` throws `shutdownTimeout`, the last durable manifest is intact, NO `master.fit` is written (no finalization of a racing stack); oracle clause 5 honest | N/A — the pipeline is glue over SessionManager (crash artifacts are the SessionManager/relay cells); a crash mid-pipeline leaves a SessionManager artifact, already covered | TEST(`testPipelineStart_sourceThrows_rollsBackRetrySucceedsNoOrphanDir`) — `start()` with a throwing source rolls back the just-created session (no orphan running dir on disk); a retry succeeds (not `alreadyRunning`); oracle on the retried session |
| **BatchImporter** (import path) | N/A — the importer produces no persistent artifact; commits flow to SessionManager (whose atomic write is the SessionManager row) | N/A — no truncatable importer artifact; a truncated *sub* is rejected at ingest (FITS row `testFITS_truncated_readerThrowsNoPartialImage`) | N/A — a sub deleted before read never reaches a worker; the importer accounts for every frame it *does* read (existing `BatchImporterTests.testAllSubsAccountedFor` verifies this contract) | N/A — the importer writes no directory; persistence is SessionManager's | N/A — the importer never writes a destination (workers register/warp in memory; commit is SessionManager's) | N/A — no replacement target at this boundary | TEST(`testBatchImporter_cancelMidImport_drainsInFlightCountTruthful`) — `cancelImport()` (via `isCancelled`) mid-import: in-flight work drains, the committed count equals `engine.acceptedCount` (truthful, no phantom/over-count), oracle passes on the partial-but-honest session | N/A — the importer is transient in-process work; a crash leaves a SessionManager artifact (that row), not an importer one | N/A — the importer is stateless across runs; recovery is a fresh import; the durable state is SessionManager's |

### Crash / relay recovery (faulthelper, all rows)

| Scenario | Test | Assertion |
|---|---|---|
| `session-midframes` | TEST(`testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean`) | SIGKILL with 3 durable snapshots → manifest parses, 3 snapshots intact + readable, `end_time` nil (running is truthful); a fresh manager starts a sibling session cleanly |
| `manifest-midwrite` | TEST(`testCrash_manifestMidwrite_killBetweenStageAndPublish_priorVersionIntact`) | SIGKILL lands DETERMINISTICALLY between staging and publication of a challenged write (the seam writer stages, flags, then blocks forever — never publishes; review4). Aftermath fully assertable: published manifest is EXACTLY the last pre-challenge version (count pinned to 123), the `.staged-<pid>` temp parses as the complete, closed, unpublished challenged version (count 124), oracle passes; the builder verifies death BY SIGKILL (uncaught signal 9) |
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
  is the future path to genuine ENOSPC/EIO — NOT added at T3: no T3 cell proved undrivable without it
  (the read-only dir drives the atomic-write failure faithfully). YAGNI held until review2, when the
  `manifest-midwrite` crash cell proved undrivable without it (see the review2 note below).
- **Crash cells use a genuine SIGKILL that lands MID-ACTIVITY.** `CrashArtifactBuilder` runs
  `faulthelper` to a coordinated readiness flag, then `kill(pid, SIGKILL)` — the aftermath is a real
  killed-mid-state directory, satisfying the spec's "terminated helper process, not merely objects
  released in-process" rule. Two cells were hardened after an oracle-evasion hunt found they were
  killing an IDLE process (flag touched AFTER the op settled):
  - `manifest-midwrite` (as hardened at review4 — see the review4 note below for the history): the
    helper pre-seeds a large (multi-MB) manifest, performs a few NORMAL staged-atomic writes through
    the injected `SessionManager.manifestWriter` seam (proving writes were flowing), then on the
    CHALLENGED write stages the full new manifest bytes to a same-dir `.staged-<pid>` temp, touches
    the readiness flag, and BLOCKS FOREVER — it never publishes. **The kill deterministically lands
    between staging and publication of the challenged write; the aftermath proves the prior
    published version survives intact** (exact pre-challenge snapshot count) beside the complete,
    closed, unpublished staged temp (exact challenged count). This is a process-crash test, not a
    power-loss test — no fsync/durability claim is made about the staged bytes.
    - **Platform note (mutation-check finding):** the prescribed mutation (switch `persist` from
      `.atomic` to `options: []`) does NOT tear on this macOS/APFS host — verified over 100+ SIGKILL
      samples at manifest sizes up to 300 MB, tear rate 0. `Data.write(options: [])` writes in-place
      (O_TRUNC + a single large `write()` syscall that the kernel completes before the SIGKILL is
      delivered), so a post-mortem reader always sees a complete version regardless of the `.atomic`
      flag. The cell therefore cannot be killed by that mutation on this platform — the OS supplies the
      guarantee. The oracle's clause-1 (parse) TEETH are proven independently by
      `FaultKitTests.testOracleHasTeeth` (a truncated manifest fails clause 1). We keep `.atomic`
      because it is the portable guarantee (other filesystems / larger-than-one-syscall writes CAN
      tear). (The mid-activity LOOP this note originally referred to was replaced at review4 by the
      deterministic block-at-pre-publish design above — the kill now always lands mid-transaction
      by construction, not by loop timing.)
  - `relay-midcopy`: see the seam justification below.
- **SEAM JUSTIFICATION — `FrameRelay.onPrePublish` (required by the `relay-midcopy` cell).** The relay
  stages src → hidden `.<name>.relaytmp`, re-stats to verify the copy, then atomically renames it into
  place. The invariant under test is "a SIGKILL between the staged copy and the publish leaves the
  `.relaytmp` present and NO glob-visible destination file." That interleaving cannot be induced
  reliably by wall-clock timing (the copy of a 64 MiB file completes in milliseconds; a flag-on-first-
  log kill fired BEFORE the staged copy even existed — the original evasion). The pre-approved
  `onPrePublish: (() -> Void)?` hook is invoked at exactly that one point; the helper sets it to
  `{ touchFlag(); blockForever() }`, so the builder's SIGKILL lands deterministically mid-copy. It is
  a synchronization point, not behavior: production leaves it nil. This was the FIRST use of a
  pre-approved seam across the pillar (the second, `SessionManager.manifestWriter`, followed at
  review2 — see below).

### Notes / justification — Task 4 (matrix completion audit)

- **One DEFECT FOUND and FIXED.** FITS row, directory-removed cell: referenced a non-existent test
  name `testWatcher_dirRemoved_survivesNoCrash`; corrected to the actual test
  `testWatcher_dirRemoved_logsOnceAndResumesOnRecreate`.
- **All N/A cross-references verified.** Every N/A cell that defers to another row was confirmed to
  terminate at a real TEST cell, not another N/A or a dangling name. Abbreviated `...` forms in
  T3 rows expanded to full test method names.
- **PROXY→T3 cells now name the test.** Both FrameRelay crash-terminated and restart-recovery cells
  now explicitly name `testCrash_relayMidcopy_noGlobVisiblePartialFreshRelayHeals`.
- **One pre-approved seam added (post oracle-evasion hunt).** `FrameRelay.onPrePublish` — the relay
  pre-publish sync hook — is now implemented and used by the `relay-midcopy` crash cell (justification
  above). The other pre-approved seam (injectable manifest writer) was NOT needed at T4 completion —
  see the review2 note below for why it became justified.
- **Total test count at pillar completion:** 30 fault-matrix tests across three suites —
  **15 file-boundary** (`FaultMatrixFileTests`), **10 lifecycle** (`FaultMatrixLifecycleTests`, of
  which 3 are the crash-terminated `faulthelper` cells), and **5 FaultKit self-tests**
  (`FaultKitTests`). 0 blank cells. Every cell TEST, N/A, or PROXY.

### Notes / justification — Outside Review #2 (review2 fix wave)

- **F1 — SessionPipeline end × master-write-fails (new cell).** The `end()` finalizer's last
  failure-prone durable artifact is the native `master.fit` write. Before the fix, `endSession()`
  (the commit point that stamps `end_time`) ran BEFORE the master write, so a failed master write
  left a manifest claiming an ended session with no persisted master — exactly the oracle clause-5
  dishonest state. FIXED by reordering: master.fit is written FIRST, `endSession()` only after the
  durable artifact lands. This adds a **read-only-destination / invalid-target-analog** cell to the
  SessionPipeline row: TEST(`testPipelineEnd_masterWriteFails_noEndTimeStampedClause5Honest`) —
  a DIRECTORY pre-placed at the master.fit path forces `Data.write` to throw; `end()` surfaces the
  failure, the manifest keeps `end_time` nil (still running = truthful), and the oracle passes
  clause 5 honestly (the ended-claim clause is exempt when `end_time` is nil). This is the regression
  proof for review2 finding F1.

- **SEAM JUSTIFICATION — `SessionManager.manifestWriter` (F3 — the SECOND pre-approved seam, named
  for the `manifest-midwrite` crash cell).** The `manifest-midwrite` crash cell asserts the
  atomic-write guarantee: whatever instant a SIGKILL lands, the on-disk manifest is SOME complete
  version, never a torn file. For that to be MEANINGFUL, the kill must land while a manifest write is
  genuinely in flight. Before this fix, the helper touched its readiness flag BEFORE the rewrite loop,
  so a fast SIGKILL could land on the pre-seeded manifest before the first challenged write ever ran —
  a vacuous pass (the cell "passed" without any write being under the kill). Wall-clock timing cannot
  reliably force the kill into the write window (each atomic write completes in a few ms). The
  pre-approved injectable `manifestWriter: ((Data, URL) throws -> Void)?` is invoked at exactly the
  persistence boundary; the helper's implementation is an explicit staged atomic write — stage the
  full bytes to a same-dir temp, touch the flag only AFTER staging has begun, then rename to publish
  — so the builder's SIGKILL, which waits for the flag, lands within an open write transaction
  (staged-but-unpublished data, or a subsequent iteration's staged write). What is NOT guaranteed:
  WHICH version survives — only that the published manifest is always some complete version, because
  publication happens solely via atomic rename of fully staged bytes. (A first cut set the flag
  before calling `write(.atomic)`, which left a preemption window between flag and write where the
  kill overlapped no write at all — review3 P2 closed it with the staged writer. Review4 then made
  the kill point fully deterministic: the challenged write now blocks forever pre-publish — see the
  review4 note below.) **Production
  safety:** the seam defaults to `nil`; when nil, `persist` runs the identical `Data(.atomic)` write
  as before (byte-for-byte behavior, existing SessionManager tests unmodified and green). It is a
  coordination/injection point, not behavior. This is the SECOND (and final) pre-approved seam used
  across the pillar — YAGNI held until this review2 evasion was found; now the cell requires it.

- **F5 — test data race in the watcher recovery test (fixed).** `testWatcher_dirRemoved_logsOnceAndResumesOnRecreate`
  captured `onLog` lines into a plain `var [String]` that the watcher's serial queue appended to while
  the test thread read it — a data race. Replaced with the lock-protected `WatcherLogSink` (the NSLock
  collector pattern used elsewhere). Swept the whole `FaultMatrixFileTests` file: the `Collector` is an
  actor (safe); the relay-cell `onLog` counters (`heals`/`unreachable`/`retries`) run synchronously
  inside `copyOnce()` on the test thread (no cross-thread access, safe); the review2-added watcher
  helpers (`WatcherLogSink`, `FolderReplaceClock`) are lock-protected. No other unprotected collectors.

### Notes / justification — Outside Review #4 (review4 fix wave)

- **P2 — `manifest-midwrite` kill point made DETERMINISTIC (supersedes the review2/review3 loop).**
  The review3 design touched the flag between stage and publish but then kept LOOPING; the builder's
  polled SIGKILL (20 ms granularity) landed many cycles later, at a RANDOM loop phase — possibly the
  re-encode gap between writes. "Lands inside an open write transaction" was a property of where the
  flag FIRST appeared, not of where the kill actually landed. FIX: the seam writer performs a few
  normal stage→publish cycles (writes provably flowing), then on the CHALLENGED write stages the full
  new bytes to `.staged-<pid>`, touches the flag, and BLOCKS FOREVER — never publishing. The kill now
  deterministically lands between staging and publication, and the cell asserts the exact aftermath:
  published manifest == the last pre-challenge version (count 123), staged temp == the complete,
  closed, unpublished challenged version (count 124), oracle green
  (`testCrash_manifestMidwrite_killBetweenStageAndPublish_priorVersionIntact`). No durability (fsync)
  claim is made about the staged bytes — this is a process-crash test, not a power-loss test. The
  seam remains justified: a block-point cannot be interposed inside production `Data(.atomic)`; the
  injected writer performs byte-identical staging steps, and the production path's crash-atomicity is
  separately covered by the APFS in-place cells.
- **P2 — CrashArtifactBuilder now VERIFIES the termination (all crash scenarios).**
  `kill(pid, SIGKILL)` must return 0 (throws `killFailed` otherwise), and after
  `Process.waitUntilExit()` the builder requires `terminationReason == .uncaughtSignal` with
  `terminationStatus == SIGKILL` (throws `notKilledBySIGKILL` otherwise) — an artifact is only valid
  if the helper died BY SIGKILL, never via a clean or errored exit. (Foundation's `Process` reaps the
  child itself; the builder deliberately does NOT call `waitpid` — that would race Process's own
  child handling.)
- **P2 — watcher mid-scan TOCTOU closed STRUCTURALLY (fd-relative enumeration).** `scan()` validates
  the watched path's (dev, ino) identity once at the top; enumeration previously ran BY PATH below
  it, so a swap landing in between applied old `lastSeenStat` observations to the NEW directory's
  files. Now enumeration and per-file stats go through the ARMED fd
  (`StackFileWatcher.enumerateDirectory(fd:)`: `openat(fd, ".", O_RDONLY|O_DIRECTORY)` →
  `fdopendir` → `readdir`; `fstatat(folderFD, name, …)`) — the fd pins the old inode, so a mid-scan
  swap is harmless by construction and the next scan's identity check resets state. No new seam and
  no timing: the structural property is unit-tested deterministically
  (`testEnumerateDirectory_pinnedFDSeesOldContentsAcrossAtomicSwap` — fd opened on dir A, dir B
  atomically renamed over A's path, fd-relative enumeration still returns A's contents). Content
  reads (FITS header + digest) remain path-based — honestly noted in the code — and are protected by
  the stability + digest gates; the path-based `fileExists` check is kept ONLY for the
  folderMissing/recovery branch, where the fd is dead by definition.
