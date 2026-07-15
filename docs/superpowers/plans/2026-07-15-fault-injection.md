# Fault-Injection Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A systematic boundary × fault test matrix for LiveAstroCore's I/O and lifecycle edges, every test verified against the session-survival oracle, with restart-recovery driven by genuine crash artifacts from a terminated helper process.

**Architecture:** `FaultKit` (test-target helpers: TempFS, CoordinatedWriter, Disruptor, SlowConsumer, CrashArtifactBuilder, OracleAssert) drives the REAL filesystem paths — no production changes except (at most) two pre-approved minimal seams gated on proven necessity in T4. A committed living matrix doc (`docs/superpowers/fault-matrix.md`) forbids blank cells: every boundary × fault is TEST, N/A-with-reason, or PROXY-with-label. A new `faulthelper` executable target produces killed-mid-operation artifacts for recovery tests.

**Tech Stack:** Swift 5.10 SPM; XCTest; DispatchSemaphore coordination (no sleeps); Process for the helper.

## Global Constraints

- **Invariant (verbatim, governs every test):** "A boundary failure may lose or reject one frame; it must never invalidate, silently corrupt, or prevent recovery of the session. Every degradation must appear honestly in the log."
- **Oracle after EVERY injected fault** (all six clauses via `OracleAssert`): durable manifest readable+parses; previously accepted frames honest; later valid frames accepted where the scenario permits; finalization recoverable; unpersisted work never reported successful; the log identifies the loss.
- **Architecture rule (verbatim):** "Exercise real filesystem behavior by default; introduce the smallest possible fault seam only for failures that cannot be induced reliably." Seams allowed ONLY in T4, only the two pre-approved forms, each justified in the matrix doc by the cell that required it.
- Temp dirs on the test process's filesystem; teardown always succeeds (restore permissions first). Semaphores/barriers, never sleeps, for coordination. Chmod-based tests probe effectiveness and `XCTSkip` with a diagnostic under privileged runners. Proxy cells labeled (read-only ≈ ENOSPC etc.), never claimed as real errno.
- LiveAstroCore imports unchanged; FaultKit lives in `Tests/LiveAstroCoreTests/FaultKit/`; `faulthelper` is a test-support executable, not shipped.
- Full `swift test` is the merge gate (filtered runs are never sufficient — house rule). iCloud build.db noise: judge by suite results; `rm -rf .build` if edits seem stale; ONE swift process at a time.
- Branch: `feature/fault-injection` off `main` @ 5a5df20. Spec: `docs/superpowers/specs/2026-07-15-fault-injection-design.md` (read its Components section before each task).

---

## Task 1: FaultKit + OracleAssert + faulthelper (TDD on itself)

**Files:**
- Modify: `Package.swift` (add `faulthelper` executable target: `.executableTarget(name: "faulthelper", dependencies: ["LiveAstroCore"])`)
- Create: `Sources/faulthelper/main.swift`
- Create: `Tests/LiveAstroCoreTests/FaultKit/TempFS.swift`, `CoordinatedWriter.swift`, `Disruptor.swift`, `SlowConsumer.swift`, `CrashArtifactBuilder.swift`, `OracleAssert.swift`
- Test: `Tests/LiveAstroCoreTests/FaultKitTests.swift`

**Interfaces produced (later tasks rely on these exact signatures):**
```swift
final class TempFS {                       // per-test sandbox
    let root: URL
    init(_ name: String) throws            // ~/tmp-equivalent on the test volume
    func dir(_ rel: String) throws -> URL  // creates subdir
    func trackPermissionChange(at: URL)    // remembered for teardown restore
    func tearDown()                        // restores perms, removes root; never throws
}

final class CoordinatedWriter {            // handshake-gated file producer
    init(url: URL)
    func writeChunk(_ data: Data)          // appends and flushes synchronously
    func truncate(to bytes: Int)
    func close()
    // Coordination is the TEST's job: writer methods are synchronous; the test
    // interleaves them with relay/watcher ticks explicitly (tick methods below).
}

enum Disruptor {
    static func deleteFile(_ url: URL) throws
    static func truncateFile(_ url: URL, to bytes: Int) throws
    static func removeDirectory(_ url: URL) throws
    @discardableResult
    static func makeReadOnly(_ url: URL, tempFS: TempFS) throws -> Bool
        // returns false (and the caller XCTSkips with a diagnostic) when a
        // write-probe shows chmod is ineffective (privileged runner)
    static func replaceWithDirectory(_ fileURL: URL) throws   // invalid replacement target
    static func replaceWithDanglingSymlink(_ url: URL) throws
}

final class SlowConsumer {                 // semaphore-gated wedge for callbacks
    let entered = DispatchSemaphore(value: 0)   // signaled when the callback wedges
    private let release = DispatchSemaphore(value: 0)
    func wedge()                            // call INSIDE the callback: signals entered, waits on release
    func releaseNow()
}

enum CrashArtifactBuilder {
    /// Runs the faulthelper executable with `scenario`, waits for its READY flag
    /// file, SIGKILLs it, and returns the directory containing the aftermath.
    static func killedArtifact(scenario: String, in tempFS: TempFS) throws -> URL
}

struct OracleExpectations {
    var lossLogPattern: String?            // regex the captured log must match (nil = no loss expected)
    var laterFramesApplicable: Bool        // clause 3 applies?
    var expectedAcceptedCount: Int?        // clause 2: exact manifest snapshot count, when known
}
func assertSessionOracle(sessionRoot: URL, log: [String],
                         _ e: OracleExpectations,
                         file: StaticString = #filePath, line: UInt = #line)
    // Clauses: (1) manifest.json at sessionRoot parses as SessionManifest;
    // (2) snapshots listed in the manifest exist on disk & count matches e.expectedAcceptedCount if set;
    // (4) replay/master finalization inputs are readable (keyframes dir consistent with manifest);
    // (5) manifest.status truthful (never 'ended' without a persisted end);
    // (6) log matches e.lossLogPattern when set. Clause (3) is asserted by the TEST
    // continuing to feed frames and checking acceptance — OracleAssert documents it via e.laterFramesApplicable.
```

**faulthelper scenarios (main.swift):** `session-midframes <root> <flag>` (SessionManager.startSession + record 3 snapshots + touch flag + block forever); `manifest-midwrite <root> <flag>` (start a session, then loop rewriting the manifest with growing snapshot lists, touching flag after the first write); `relay-midcopy <src> <dst> <flag>` (start a FrameRelay against a large source, touch flag after the first tick begins). Each scenario touches `<flag>` at its coordinated point then blocks on a never-signaled semaphore so SIGKILL lands mid-state.

- [ ] **Step 1: Write FaultKitTests (failing)** — tests that pin FaultKit itself:
  - `testTempFSTeardownAfterReadOnlyFlip` (flip a subdir read-only, tearDown succeeds, root gone)
  - `testCoordinatedWriterChunksVisibleImmediately` (writeChunk → file size reflects it synchronously)
  - `testDisruptorReadOnlyProbeDetectsPrivilege` (on a normal runner returns true and writes then fail; the skip path is code-reviewed not simulated)
  - `testCrashArtifactBuilderProducesKilledSession` (scenario `session-midframes` → returned dir has a manifest with 3 snapshots and status running — a genuine mid-flight artifact)
  - `testOracleHasTeeth` (build a valid 2-snapshot session, then corrupt: (a) truncate manifest.json → oracle FAILS clause 1; (b) delete a listed snapshot file → FAILS clause 2; (c) hand-edit status to ended without endedAt → FAILS clause 5 — use `XCTExpectFailure` around each)
- [ ] **Step 2: Verify fail** — `swift test --filter FaultKitTests` (compile errors for missing types count).
- [ ] **Step 3: Implement FaultKit + faulthelper + Package.swift change.** Keep each helper under ~120 lines; OracleAssert reads `SessionManifest` via the production Codable type (`@testable import LiveAstroCore`).
- [ ] **Step 4: Verify pass** — `swift test --filter FaultKitTests` green; then `swift build` (whole package incl. faulthelper compiles).
- [ ] **Step 5: Commit** — `git add Package.swift Sources/faulthelper Tests/LiveAstroCoreTests/FaultKit Tests/LiveAstroCoreTests/FaultKitTests.swift && git commit -m "feat(faultkit): deterministic fault-injection harness + session oracle + crash helper (TDD)"`

---

## Task 2: File-boundary matrix rows (FITS ingest · FrameRelay · RelayPruner · StackFileWatcher)

**Files:**
- Create: `Tests/LiveAstroCoreTests/FaultMatrixFileTests.swift`
- Create: `docs/superpowers/fault-matrix.md` (started: header, rules, these four rows)

**Interfaces consumed:** FaultKit (T1 signatures above); `FrameRelay(source:destination:glob:)` + `start()/stop()` + the test-visible tick seam used by existing FrameRelayTests (READ `Tests/LiveAstroCoreTests/FrameRelayTests.swift` first and reuse its tick/temp patterns); `StackFileWatcher(folder:quietPeriod:pollInterval:)` + its test seams (READ its tests); `FITSReader.read(_:)`; `RelayPruner.prune(root:olderThanDays:now:excluding:)`.

Fault columns for these rows: mid-write/growing · truncated · deleted-mid-run · dir-removed · read-only dest · invalid replacement target. (Slow-consumer and crash columns are N/A here — noted in the matrix with reasons; relay crash-termination is covered in T3 via faulthelper.)

For every cell: arrange with FaultKit → inject at a coordinated point → assert component-level behavior (skip/reject/heal/log) → **finish with the oracle where a session exists**, or with the component-level honesty assertions (log line + no partial output) where the boundary predates a session (FITS reader, pruner). One fully-worked exemplar per fault type; remaining cells follow the same shape with the scenario table below.

- [ ] **Step 1: Write the cell tests (failing where they expose gaps, passing where the fix wave already covers — EXPECTED: most pass immediately; the deliverable is systematic coverage, and any RED test found here is a real bug → STOP and report it before "fixing" the test).** Cells:

| Cell | Scenario (arrange → inject → expect) |
|---|---|
| FITS × truncated | valid header, pixel data cut at 60% → `FITSReader.read` throws (no partial AstroImage); via pipeline: frame rejected + logged, session continues |
| FITS × mid-write | CoordinatedWriter emits header only, watcher tick, then pixels, tick → emitted exactly once, complete |
| FITS × invalid-replacement | path is a directory named `x.fit` → reader throws / watcher skips with log |
| Relay × mid-write/growing | (exists — extend) grow across ticks → never published until stable; assert temp never visible to glob |
| Relay × truncated-dest | (exists: healing) truncated dest + stable source → healed once, `relay healed` log |
| Relay × deleted-mid-run | delete source between stability-pass and next tick → no publish, no crash, pending entry cleared |
| Relay × dir-removed | remove SOURCE dir mid-run → relay logs and keeps ticking (no crash); restore dir → resumes |
| Relay × read-only dest | flip dest dir read-only (probe first) → copy fails, logged, retried after restore; no temp litter |
| Pruner × read-only | read-only session dir inside relay root → prune skips it (best-effort), returns others, no throw |
| Pruner × invalid-replacement | dangling symlink dir-entry in relay root → skipped (isDirectory false), untouched |
| Watcher × mid-write/growing | (exists — systematize) preallocated + mtime-bumping file → not emitted until stable |
| Watcher × deleted-mid-run | file deleted between size-check and read → no emit, no crash, next file fine |
| Watcher × dir-removed | watched folder removed mid-run → watcher survives (no crash), logs once, resumes on recreate |

- [ ] **Step 2: Run** — `swift test --filter 'FaultMatrixFile|FrameRelay|StackFileWatcher|RelayPruner'`. Any RED = real gap: STOP, report the failing scenario with its output to the controller (do not weaken the test).
- [ ] **Step 3: Start `docs/superpowers/fault-matrix.md`** — table with these rows fully filled (TEST names / N/A reasons / PROXY labels: read-only ≈ ENOSPC proxy, noted).
- [ ] **Step 4: Commit** — `"test(faultmatrix): file-boundary rows — FITS, relay, pruner, watcher (+ matrix doc)"`

---

## Task 3: Lifecycle matrix rows (SessionManager · SnapshotRecorder · SessionPipeline · BatchImporter) + crash recovery

**Files:**
- Create: `Tests/LiveAstroCoreTests/FaultMatrixLifecycleTests.swift`
- Modify: `docs/superpowers/fault-matrix.md` (add these rows)

**Interfaces consumed:** FaultKit; `SessionManager` (startSession/recordSnapshot/endSession, SessionError); `SnapshotRecorder.save(...)`; `SessionPipeline` (init(nativeSource:...), start/end, onLog, SessionPipelineError.shutdownTimeout); `BatchImporter` via pipeline import path; `CrashArtifactBuilder` scenarios from T1.

Cells (same discipline; oracle after every one):

| Cell | Scenario |
|---|---|
| SessionManager × read-only mid-session | start OK, flip session dir read-only, recordSnapshot → throws, in-memory state unchanged (fix-wave behavior systematized), restore → later snapshots accepted; oracle: counts truthful |
| SessionManager × dir-removed mid-session | remove session dir after N snapshots → next record throws honestly; oracle on the REMAINS: no false success |
| SnapshotRecorder × read-only / dir-removed | save fails cleanly; pipeline path logs `frame dropped`; session continues; oracle: manifest never lists the unsaved snapshot |
| Pipeline start × source-throws | (fix-wave rollback — systematize) start fails → retry succeeds; no orphan running session on disk |
| Pipeline end × wedged consumer | (fix-wave shutdownTimeout — systematize with SlowConsumer) end() throws shutdownTimeout; oracle: last durable manifest intact, no finalization of a racing stack |
| Pipeline mid-session × frame flood + one hostile file | mixed stream: valid, truncated, valid → exactly the truncated one rejected+logged, both valids accepted (invariant clause: lose a frame never the session) |
| BatchImporter × cancel mid-import | cancelImport() during a coordinated import → in-flight drained, committed count truthful, oracle passes on the partial-but-honest session |
| Crash × session-midframes | faulthelper killed with 3 recorded snapshots → REOPEN with a fresh SessionManager on the same root: manifest parses, 3 snapshots intact, status running (truthful — it WAS running); a new session in a sibling dir starts cleanly (recovery = the data is recoverable + a fresh start isn't blocked) |
| Crash × manifest-midwrite | helper killed mid-rewrite → manifest is EITHER the previous complete version OR the new complete version (atomic write guarantee), never a torn file; oracle clause 1 |
| Crash × relay-midcopy | helper killed mid-copy → destination contains no partial visible file (temp only, invisible to glob); a fresh relay over the same dirs completes the copy (heals) |

- [ ] **Step 1: Write the cell tests** (same STOP-on-RED rule — a red here is a found bug, report it).
- [ ] **Step 2: Run** — `swift test --filter 'FaultMatrixLifecycle|SessionManager|SessionPipeline|BatchImporter|FaultKit'`.
- [ ] **Step 3: Update the matrix doc** with these rows.
- [ ] **Step 4: Commit** — `"test(faultmatrix): lifecycle rows + crash-artifact recovery (SessionManager, pipeline, importer)"`

---

## Task 4: Matrix completion audit (+ seams only if proven necessary)

**Files:**
- Modify: `docs/superpowers/fault-matrix.md` (final: every cell TEST/N/A/PROXY, no blanks)
- Possibly modify (ONLY if a T2/T3 cell was reported undrivable): `Sources/LiveAstroCore/Session/SessionManager.swift` (injectable `manifestWriter` seam) and/or `Sources/LiveAstroCore/Live/FrameRelay.swift` (`onPrePublish` sync hook) — smallest form per the spec, with a justification note in the matrix doc naming the cell.

- [ ] **Step 1: Audit** — cross-check every boundary × fault against T2/T3 test names; fill N/A cells with one-line reasons; label PROXY cells (read-only ≈ ENOSPC; dir-removed ≈ volume disconnect).
- [ ] **Step 2: Seams** — implement ONLY what T2/T3 reported undrivable (default expectation: none). If added: TDD the seam's failure path + oracle, document the justification.
- [ ] **Step 3: Full gate** — `swift test` (0 failures) and `swift build -c release`.
- [ ] **Step 4: Commit** — `"docs(faultmatrix): completion audit — every cell TEST/N/A/PROXY"`

---

## After all tasks

Whole-branch review (opus — focus: oracle rigor, no vacuous tests, no sleeps, matrix honesty) + a cold pass focused on "can any fault test pass while the invariant is actually violated?" Then merge + push (no dist repackage needed unless production seams were added — test-only changes don't alter the app binary; repackage only if Package.swift/product changes affect the build).
