# Fault-Injection Coverage — Design

**Date:** 2026-07-15
**Branch:** `feature/fault-injection` (off `main` @ ea2a227)
**Status:** approved for planning
**Stabilization step 2 of 6** (plan of record, ledger 2026-07-15).

## Problem

The stacking algorithms earned systematic adversarial rigor; the I/O and lifecycle boundaries did not. The external-review fix wave (merged ea2a227) closed the *known* sharp edges — relay partial copies, watcher preallocation, drain timeout, non-transactional persistence, startup rollback — each with a targeted regression test. What does not yet exist is **systematic** coverage: a deliberate matrix of boundary × fault with a single honest acceptance criterion, so the next sharp edge is found by our suite instead of a reviewer or a lost night.

## The Invariant and the Oracle (verbatim; governs every test in this pillar)

**Invariant:** *A boundary failure may lose or reject one frame; it must never invalidate, silently corrupt, or prevent recovery of the session. Every degradation must appear honestly in the log.*

**Oracle — verified after every injected fault:**
1. The last durable manifest remains readable and parses.
2. Previously accepted frames remain honest (still present in the durable stack / counts truthful).
3. Later valid frames continue to be accepted, where the scenario permits.
4. Finalization produces recoverable output.
5. Unpersisted work is never reported as successful.
6. The log identifies the loss/degradation.

## Governing Architecture Rule (verbatim)

*Exercise real filesystem behavior by default; introduce the smallest possible fault seam only for failures that cannot be induced reliably.*

Consequences:
- **No general filesystem abstraction.** The 17 direct `FileManager` call sites stay as they are; tests drive the real paths.
- **Two pre-approved minimal seams**, added ONLY if a matrix cell proves undrivable without them, each with a justification note in the matrix doc:
  - an **injectable manifest writer** at `SessionManager`'s atomic-write boundary (deterministic persistence failure — future ENOSPC/EIO coverage);
  - a **synchronization hook** at `FrameRelay`'s copy-verified-before-publish point (deterministic interleaving instead of sleeping until a race probably occurs).
- **Proxy honesty:** chmod/read-only and directory-removal cases are documented as *proxies* for disk-full and raw EIO — never claimed as the real errno.

## Engineering Rules (verbatim from design discussion)

- Temp directories on the **same filesystem as the test process**; teardown always succeeds (restore permissions before removal).
- Coordinate growing writers and slow consumers with **barriers/semaphores, not timing guesses or long sleeps**.
- Verify the **full oracle after every fault** — no fault test ends without `OracleAssert`.
- Test restart/recovery from artifacts built by a **terminated helper process** — not merely objects released in-process.
- Treat chmod carefully: privileged runners can defeat it — chmod-based tests detect that condition and **skip with a diagnostic** rather than pass vacuously; also cover directory removal, read-only destinations, and invalid replacement targets, since permission behavior varies.

## Components

### 1. FaultKit — `Tests/LiveAstroCoreTests/FaultKit/` (test target only)

Small, composable, deterministic helpers:

- **`TempFS`** — creates per-test directories under the test process's temp filesystem; tracks every permission change and restores it in teardown; removal is unconditional and non-throwing at the end of every test.
- **`CoordinatedWriter`** — writes/grows a file in steps gated by `DispatchSemaphore` handshakes with the test (`writeChunk() → signal → wait`). Models: mid-write (partial content, still open), pause-resume across watcher/relay ticks, truncate-then-continue. No sleeps; every interleaving is explicit.
- **`Disruptor`** — applies a named disruption at a coordinated point: delete file, truncate file, remove directory tree, flip destination read-only, replace a path with an invalid target (dir where a file is expected, dangling symlink). Chmod-based disruptions first verify chmod is effective for this process (write-probe) and `XCTSkip` with a diagnostic if privileged.
- **`SlowConsumer`** — semaphore-gated blocking inside pipeline callbacks (`onUpdate`/rejection seams), generalizing the drain-timeout test pattern: the test controls exactly when the consumer wedges and when (if ever) it releases.
- **`CrashArtifactBuilder`** — drives a **separate helper executable** (new SPM executable target `faulthelper`, test-support only, not shipped in the app bundle) that starts a real operation (begin session + accept N frames; relay mid-copy; manifest mid-write) and blocks on a named pipe/file flag at a coordinated point; the test SIGKILLs it and receives the genuine on-disk aftermath. Restart/recovery tests then run the real components against those artifacts.
- **`OracleAssert`** — one function, `assertSessionOracle(root:log:expectations:)`, that checks all six oracle clauses against a session root and captured log lines. Every fault test's final statement. Scenario-specific expectations (e.g., "frame N lost", "later frames not applicable — session ended") are explicit parameters, so the oracle is never silently weakened.

### 2. The Fault Matrix — `docs/superpowers/fault-matrix.md` (living document, committed)

Rows (boundaries): FITS ingest (reader on hostile files), FrameRelay, RelayPruner, StackFileWatcher, SessionManager, SnapshotRecorder, SessionPipeline start/end, BatchImporter cancel/error.
Columns (faults): mid-write/growing · truncated · deleted-mid-run · directory-removed · read-only destination · invalid replacement target · slow/hung consumer · crash-terminated (helper) · restart-recovery.

Every cell is one of: **TEST** (named test), **N/A** (with one-line reason), or **PROXY** (test exists; documents which real fault it approximates — e.g. read-only ≈ ENOSPC). No blank cells. The matrix doc is updated in the same commit as its tests; a stale matrix is a review defect.

Expected density: many cells are N/A (e.g. slow-consumer only applies to the pipeline; crash-termination applies to writers not readers). The estimate is ~35–45 real tests.

### 3. Seams (only if proven necessary — Task 4 gate)

If (and only if) a matrix cell cannot be driven reliably by FaultKit, add the pre-approved seam, smallest form:
- `SessionManager`: `var manifestWriter: (Data, URL) throws -> Void` (default = current atomic write) — injectable failure at exactly the atomic-write boundary.
- `FrameRelay`: a test-only `onPrePublish: (() -> Void)?` hook invoked between copy-verification and rename — a synchronization point, not behavior.
Each seam ships with a justification note in the matrix doc naming the cell that required it. If no cell requires them, they are NOT added (YAGNI).

## What this pillar does NOT do

- No multi-hour soak tests in the default suite (a release-gated, env-opt-in soak may be a later follow-on, PerformanceTests pattern).
- No OBS/GraXpert/UI coverage (mock socket and existing tests cover the first two; UI is out of core).
- No claim of real ENOSPC/EIO coverage — proxies are labeled, and the manifest-writer seam is the future path to the real thing.
- No production-code changes beyond (at most) the two pre-approved seams.

## Testing the tests

FaultKit itself is TDD'd: `CoordinatedWriter` handshake ordering, `TempFS` teardown after permission flips, `Disruptor` privileged-skip detection, `CrashArtifactBuilder` producing a killed-mid-write artifact, `OracleAssert` failing loudly on a seeded violation (a deliberately corrupt manifest must FAIL the oracle — the oracle test proves the oracle has teeth).

## Global Constraints

- Swift 5.10, macOS 14+. FaultKit lives in the test target; `faulthelper` is a test-support executable target; LiveAstroCore imports unchanged (Foundation/CoreGraphics/Accelerate only).
- Deterministic: no sleeps as synchronization; semaphores/barriers only. Chmod tests skip-with-diagnostic when privileged.
- Full `swift test` remains the merge gate; the matrix must show no blank cells at pillar completion.
- Production code untouched except (at most) the two pre-approved minimal seams, each justified in the matrix doc.

## Task Order (for the plan)

1. **T1 — FaultKit + OracleAssert (TDD on itself)** incl. the `faulthelper` executable target and the oracle-has-teeth test.
2. **T2 — File-boundary matrix rows:** FITS ingest, FrameRelay, RelayPruner, StackFileWatcher (× applicable fault columns), matrix doc started.
3. **T3 — Lifecycle matrix rows:** SessionManager, SnapshotRecorder, SessionPipeline start/end, BatchImporter, crash-terminated + restart-recovery scenarios via `faulthelper`.
4. **T4 — Matrix completion audit:** every cell TEST/N/A/PROXY with reasons; add a pre-approved seam ONLY where a cell proved undrivable (with justification); final matrix doc committed.
