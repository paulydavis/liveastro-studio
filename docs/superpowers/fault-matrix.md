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
| **StackFileWatcher** | TEST(`testWatcher_midWriteGrowing_notEmittedUntilStable`) — preallocated + mtime-bumping file not emitted until stable, then exactly once | PROXY→existing — truncated FITS rejection is covered by the FITS row's `testFITS_truncated_watcherRejectsThenAcceptsComplete` and existing `StackFileWatcherTests.testIgnoresPartialFITSUntilComplete` (size < `minimumFileSize` gate) | TEST(`testWatcher_deletedMidRun_noCrashNextFileFine`) — file deleted after emit: no crash, no re-emit, a new file still ingests | PROXY(partial — see FOUND-BUG) — `testWatcher_dirRemoved_survivesNoCrash` — folder removed mid-run: survives (no crash), no spurious emit; recovery requires a FRESH watcher. **Gap:** no live-resume and no log line (watcher has no `onLog`, `scan()` swallows the missing dir silently) — invariant clause 6 unmet. See report FOUND-BUG. | N/A — the watcher only reads the watched folder; it never writes a destination | N/A(covered by FITS row) — a directory named `*.fit` in the watched folder is exercised in `testFITS_invalidReplacement_directoryNamedFit` (watcher skips, no emit) | N/A(here) — the slow/hung consumer is a downstream-of-watcher pipeline concern (drain-timeout), T3 row | N/A — watcher is a reader; crash-mid-write applies to the writer feeding it | N/A(here) — watcher holds only in-memory stat/digest state; recovery is a fresh `start()` (see dir-removed) |

### Notes / justification for proxies and gaps

- **read-only ≈ ENOSPC/EIO**: chmod is a *proxy* for a full/failing destination. The real errno is
  not claimed. The future path to genuine ENOSPC/EIO is the pre-approved injectable manifest writer
  (spec §Seams), added only if a T3/T4 cell proves undrivable without it. Not needed for Task 2.
- **FOUND-BUG — StackFileWatcher directory-removed** (yield of this pillar): when the watched folder
  is removed mid-run, `StackFileWatcher.scan()` degrades to *silent* idle — it has no `onLog` seam,
  so clause 6 ("every degradation must appear honestly in the log") is unmet; and a live watcher does
  **not** resume when the folder is recreated at the same path (the `O_EVTONLY` fd is bound to the
  deleted inode and is never re-opened on `ENOENT`). Recovery is only possible by constructing a new
  watcher. The test asserts the survivable, deterministic part and documents the gap; the fix
  (a log line + re-open-on-ENOENT, or an `onLog` seam) is a production change deferred to the
  matrix-completion audit / a follow-on, per the "no production changes beyond the two pre-approved
  seams in this pillar" rule.

## Rows — Lifecycle boundaries (Task 3, pending)

SessionManager · SnapshotRecorder · SessionPipeline start/end · BatchImporter — to be filled by T3,
including crash-terminated + restart-recovery via the `faulthelper` executable.
