# Inter-frame Import Batching (N-way) — Design

**Date:** 2026-07-12
**Branch:** `feature/parallel-import` (off `main` @ f21a7d7)
**Status:** approved for planning
**Context:** Sub-pillar 2 of 2 of multithreaded stacking. Sub-pillar 1 (intra-frame, per-pixel loops) shipped on main @ f21a7d7.

## Problem

Folder Import processes subs strictly serially: `for await frame in source.frames { engine.process(frame) }` — load one sub (FITS read + parse) → register + warp + accumulate → next. Sub-pillar 1 parallelized each frame's *pixel* loops, but subs are still handled one at a time. On a many-core Mac importing dozens of 26MP subs, frame-level parallelism can further raise throughput.

## Goal

Import a folder of subs using a **frame-per-core** worker pool: each worker processes one whole sub, filling all cores at the frame level. Faster batch import, correct final stack (identical accepted/rejected set and coverage; final mean within float epsilon of serial). Live/watch-folder stacking is unchanged.

## Non-Goals

- No change to the live (watch-folder) path — it stays serial (frames trickle in one at a time; nothing to batch).
- No byte-identical guarantee for import (accumulation order varies with completion order → ~1e-6 float difference; deliberately accepted — see Determinism).
- No mid-batch auto-reseed (batch import assumes one coherent target).
- No ordered-reduce / partial-accumulator merge (locked-add in completion order chosen for memory).

## Key design decision — avoid oversubscription

Because sub-pillar 1 already fans each frame's pixel work across all cores, running N subs *and* intra-frame parallelism at once would oversubscribe. So during batch import, **intra-frame parallelism is suppressed per worker** (each stage called with `minRows: .max` → serial), and the pool size = core count. Total live threads = pool size, not pool × cores. Frame-level parallelism has less dispatch overhead than fine-grained row bands, so this is efficient, not contended.

## Architecture

### 1. `StackEngine` staged API (split `process` into concurrent-friendly stages)

The current `StackEngine.process(_:)` does detect→match→solve→warp→accumulate atomically under one lock. Add staged methods so registration/warp can run concurrently while accumulation stays coordinated. The existing `process` stays (live path uses it unchanged).

```swift
public struct RegisteredFrame {            // result of register(); ready to warp+commit
    let transform: SimilarityTransform     // half-res transform (lift to full-res in warp)
    let rgb: AstroImage                     // display-oriented RGB (debayered/flipped)
}

extension StackEngine {
    /// Establish the fixed reference from `frame` if it has ≥ seedMinStars.
    /// Returns true on success. Serial — call before any concurrent register().
    func seedReference(_ frame: RawFrame, minRows: Int) -> Bool

    /// Register `frame` against the ALREADY-SEEDED, immutable reference.
    /// Lockless-safe to call concurrently (reads reference state read-only; mutates
    /// nothing). Returns nil if rejected (too few stars / no transform / dim mismatch).
    func register(_ frame: RawFrame, minRows: Int) -> RegisteredFrame?

    /// Warp a registered frame to reference alignment (concurrent-safe, pure).
    func warp(_ reg: RegisteredFrame, minRows: Int) -> (image: AstroImage, mask: [Float])

    /// Accumulate a warped frame into the shared stack UNDER THE ENGINE LOCK.
    /// Bumps acceptedCount + frameCount. Safe to call from multiple threads.
    func commit(image: AstroImage, mask: [Float], minRows: Int)

    /// Record a rejection under the lock (bumps rejectedCount). For batch use.
    func commitRejection()
}
```

The reference state (`referenceStars`, `referenceSize`, `referenceChannels`) is set once by `seedReference` and never mutated during the concurrent phase (no mid-batch reseed), so concurrent `register` reads are race-free without a lock. `commit`/`commitRejection` take the existing `lock`.

### 2. `BatchImporter` (NEW, `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`)

Orchestrates a folder import over a bounded worker pool. Import-only.

```swift
public final class BatchImporter {
    public init(engine: StackEngine, poolSize: Int? = nil)   // default: sane cap of activeProcessorCount
    /// Pull frames from `source` (a finite importOnce FrameSource), seed serially on
    /// the first frame with enough stars, then register+warp the rest across the pool,
    /// committing each result under the engine lock in completion order.
    /// onProgress(processed, total?, accepted, rejected) fires as frames complete.
    public func run(source: FrameSource,
                    onProgress: @escaping (Int, Int?, Int, Int) -> Void,
                    isCancelled: @escaping () -> Bool) async
}
```

Flow:
1. Pull subs from `source.frames`. For each, until seeded: call `seedReference` serially; the first that returns true becomes the reference (its frame is the seed and counts as accepted). Frames that fail to seed (too few stars) are counted rejected.
2. Once seeded, feed remaining subs into a bounded pool (`poolSize` concurrent workers). Each worker: `register` → if non-nil `warp` → `commit`; else `commitRejection`. All stage calls use `minRows: .max` (intra-frame off).
3. `onProgress` fires per completed frame (order-independent counts).
4. Respect `isCancelled` — stop feeding new frames; in-flight workers finish; already-committed frames remain (valid partial master, matching current cancel semantics).

**Pool size:** default `max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))`. The cap of 6 bounds peak memory (~700 MB per in-flight 26MP frame → ~4 GB) on machines with many cores. `poolSize:` override allows tuning/testing.

### 3. Wiring — `SessionPipeline` import path

`SessionPipeline`'s native importOnce consume loop (currently `for await frame in src.frames { handleNative }`) routes through `BatchImporter` when the source is finite (importOnce). The per-frame finalize (snapshot recording, `onImportProgress`) is driven from `BatchImporter`'s `onProgress` and the commit hook. Live (watch-folder) mode keeps the existing serial `handleNative` loop untouched.

Progressive snapshots (for the import replay) are recorded on each commit (completion order); the stack grows monotonically so the evolution video stays coherent.

## Determinism

Registration is deterministic per frame (each frame independently solves its transform against the fixed reference), so:
- The **set of accepted/rejected frames is identical to serial** — exact.
- The **coverage map is identical to serial** — `weight[i]` sums binary mask values (0/1); integer-valued float sums are exact regardless of order.
- The **final mean differs from serial only by float-accumulation order** — `sum[i] += …` runs in completion order, not file order. Max abs pixel difference is ~1e-6 (invisible). This is the deliberate tradeoff for memory-light locked-add.

## Error Handling

- **Cancellation:** `isCancelled` checked before feeding each new sub; in-flight workers complete; the accumulator holds all committed frames → a valid partial master (matches current Import cancel behavior).
- **Seed never established** (no sub has ≥ seedMinStars): import completes with 0 accepted, all rejected; the pipeline reports this (no crash, no master).
- **A worker throwing / bad sub:** a sub that fails to load is skipped (counted rejected); `register` returning nil is a normal rejection. No single bad sub aborts the batch.
- **Thread safety:** concurrent `register`/`warp` read only immutable reference + their own frame; `commit` serializes accumulator writes under the engine lock; counters bumped under that lock.

## Testing

**Core, TDD (`Tests/LiveAstroCoreTests/BatchImporterTests.swift` + StackEngine staged-API tests):**
- **Parity of outcome vs serial:** build a synthetic set of N registerable subs; run serial `StackEngine.process` over them and `BatchImporter` over them; assert **equal** `acceptedCount`, `rejectedCount`, and coverage map; assert final mean **≈** equal within `1e-4` max abs diff.
- **Seed selection:** a leading low-star sub is rejected for seeding; the first ≥seedMinStars sub becomes the reference; later subs register against it.
- **All subs processed:** N subs in → accepted+rejected == N.
- **Cancellation:** cancel partway → committed frames form a valid partial stack; no crash.
- **Staged API units:** `register` returns nil for too-few-stars / no-transform / dim-mismatch; `warp` matches `Warp.apply(rgb, transform.liftedToFullResolution())`; `commit` bumps counts and equals `accumulator.add`.
- **Thread safety (stress):** import a modest set with `poolSize` > 1 repeatedly; counts stay correct (no lost/double commits).

App/UI (Import button already exists) = build/manual-verified: import a real folder, confirm faster wall-clock and a correct master.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `BatchImporter` uses Foundation/Dispatch.
- Zero external dependencies.
- Core logic TDD'd (`swift test --filter LiveAstroCoreTests`).
- Live (watch-folder) path unchanged; batching is import-only.
- Reuses sub-pillar-1's `minRows` knobs (called with `.max` to suppress intra-frame fanout per worker).
- New source group entries under `Sources/LiveAstroCore/Pipeline/` and `Stacking/`.

## Task Order (for the plan)

1. **T1 — `StackEngine` staged API (TDD).** `RegisteredFrame` + `seedReference`/`register`/`warp`/`commit`/`commitRejection`, with unit tests proving each stage equals the monolithic `process` path. The existing `process` stays for live.
2. **T2 — `BatchImporter` orchestrator (TDD).** Pool + seed-then-parallel + locked-commit; outcome-parity + seed-selection + cancellation + stress tests.
3. **T3 — Wire `SessionPipeline` import path through `BatchImporter` (build/integration-verified).** Route importOnce through the batch importer; keep progress/snapshot hooks; live path untouched.
