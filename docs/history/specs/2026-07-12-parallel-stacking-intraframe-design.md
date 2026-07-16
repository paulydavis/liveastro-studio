# Multithreaded Stacking — Intra-frame Parallelism — Design

**Date:** 2026-07-12
**Branch:** `feature/parallel-stacking` (off `main` @ 8996ace)
**Status:** approved for planning
**Context:** Sub-pillar 1 of 2. Sub-pillar 2 (inter-frame import batching) is a separate later spec.

## Problem

The native stacker processes each frame single-threaded. For Paul's 26MP ASI2600 subs (6248×4176), the pixel-O(N) loops — inverse-mapped warp, debayer, half-res luminance, weighted accumulate — dominate per-frame time and run on one core. His own asiair-livestack notes full-res registration is slow. This makes live stacking laggy and import slow. Modern Macs have many idle cores.

## Goal

Parallelize the four pixel-bound loops across cores so each frame is processed faster, cutting live latency and import time. The result must be **byte-identical** to today (pure speed; no image-quality change). Benefits both live and import (each frame processed faster).

## Non-Goals

- No inter-frame batching (concurrent multi-sub processing) — that is sub-pillar 2.
- No `StarDetector` parallelization — it runs on half-res luminance (smaller) and its connected-components structure is not a clean row split. Leave serial for v1; note for later.
- No image-quality/algorithm change. No user-facing toggle. No external dependencies (Dispatch only).

## Architecture

Each targeted loop already writes disjoint outputs per row (or per pixel index), so splitting the outer row loop into contiguous **row bands** run concurrently is race-free with no locks. `StackEngine.process()` keeps its per-frame `lock` and serial accumulator model unchanged — parallelism happens strictly *within* a frame, and `DispatchQueue.concurrentPerform` blocks until all bands join before the function returns.

### Shared helper — `Sources/LiveAstroCore/Util/Parallel.swift` (NEW)

```swift
enum Parallel {
    /// Run `body` over contiguous row bands of [0, height) concurrently across
    /// cores. Below `minRows`, runs a single serial band (avoids GCD overhead on
    /// small/test images). Bands are disjoint row ranges; `body` must write only
    /// rows in its given range. Blocks until all bands complete.
    static func rows(_ height: Int, minRows: Int = 64, _ body: (Range<Int>) -> Void)
}
```

Implementation: if `height < minRows` (or `activeProcessorCount <= 1`), call `body(0..<height)` once. Otherwise split into `bandCount = min(ProcessInfo.processInfo.activeProcessorCount, height)` contiguous bands and `DispatchQueue.concurrentPerform(iterations: bandCount)` with each iteration computing its `[lo, hi)` row range and calling `body(lo..<hi)`. Band boundaries: `lo = b * height / bandCount`, `hi = (b+1) * height / bandCount` (covers all rows exactly, no gaps/overlap).

### The four call sites

Each is refactored so the per-row work moves into a `Parallel.rows(h) { rowRange in for y in rowRange { … } }` closure, with the output buffer accessed via `withUnsafeMutableBufferPointer` (a `let` pointer captured by the closure; disjoint-row writes are safe). Each public function gains one defaulted internal knob `minRows: Int = 64` (threaded into `Parallel.rows`) so tests can force serial vs parallel on the same input. Existing callers are unaffected.

1. **`Warp.apply(_:transform:minRows:)`** (`Stacking/Warp.swift`) — parallelize the `for y in 0..<h` loop; each band writes its rows of `out` (all channels) and `mask`. The biggest win.
2. **`Debayer.bilinear(cfa:pattern:minRows:)`** (`Stacking/Debayer.swift`) — parallelize its output-row loop.
3. **`StackEngine.halfResLuminance(frame:minRows:)`** (`Stacking/StackEngine.swift`, static) — parallelize the `for j in 0..<hh` band; height is `hh` (half-res).
4. **`StackAccumulator.add(_:mask:minRows:)`** (`Stacking/StackAccumulator.swift`) — parallelize over rows; each pixel index `i` is written by exactly one row, so `sum`/`weight` updates are disjoint. (The accumulate loop is currently flat `for i in 0..<plane`; refactor to `for row; for col` over the same buffers so it can band by row.)

`StackEngine.process` and `displayRGB` call these with default `minRows` (parallel above threshold). No signature change visible to `AppModel`/pipeline.

## Determinism — the core guarantee

Every output element is computed **independently**: Warp/Debayer/luminance write distinct output indices; the accumulator adds to each `sum`/`weight` index exactly once per frame. There is **no cross-thread reduction and no shared-index write**, so the parallel result is **bit-identical** to the serial result regardless of band count or scheduling. Floating-point associativity is not a factor because no sum is split across threads.

## Error Handling / Safety

- `Parallel.rows` with `height == 0` runs zero work (guard `height > 0` before dispatch).
- `withUnsafeMutableBufferPointer` + `concurrentPerform` is the standard disjoint-write pattern; no data race because bands write non-overlapping index ranges. Shared reads (`src`, `inv`, weights) are read-only.
- Holding `StackEngine.lock` across `concurrentPerform` is fine — it blocks until join; no async escape, no lock inversion.

## Testing

**Core, TDD (`Tests/LiveAstroCoreTests/`):** a parity test per loop — same input run through forced-serial (`minRows: .max`) and forced-parallel (`minRows: 0`) paths, assert **byte-identical** output:
- `WarpParallelTests` — a ≥128-row 3-channel image with a non-trivial `SimilarityTransform`; assert `out.pixels == out.pixels` and `mask == mask` across the two paths.
- `DebayerParallelTests` — a ≥128-row CFA; assert identical RGB.
- `HalfResLuminanceParallelTests` — a ≥256-row frame; assert identical luminance (call via `@testable` static).
- `StackAccumulatorParallelTests` — add the same image+mask through both paths into two accumulators; assert identical `mean()` (and coverage).
- Plus: existing Warp/Debayer/Accumulator/StackEngine correctness tests must still pass unchanged (behavior preserved).
- A `Parallel.rows` unit test: bands cover `[0,height)` exactly (each row visited once) for representative heights incl. non-divisible ones, and the `< minRows` serial path runs one band `0..<height`.

**Perf (manual/non-gating):** a `swift build -c release` run stacking real 26MP subs to sanity-check wall-clock improvement — recorded, not asserted (perf is machine-dependent).

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `Parallel` uses Foundation/Dispatch only.
- Zero external dependencies.
- Byte-identical output vs the current serial implementation (regression-guarded by parity tests + existing suite).
- Core logic is TDD'd (`swift test --filter LiveAstroCoreTests`).
- `StackEngine` per-frame lock + serial accumulator model unchanged; parallelism is intra-frame only.
- Public signatures gain only defaulted internal params; external callers unchanged.

## Task Order (for the plan)

1. **T1 — `Parallel.rows` helper (TDD).** The banding utility + its unit tests. Shared foundation for the rest.
2. **T2 — `Warp.apply` parallel + parity test.** The biggest loop; proves the pattern end-to-end.
3. **T3 — `Debayer.bilinear` parallel + parity test.**
4. **T4 — `StackEngine.halfResLuminance` + `StackAccumulator.add` parallel + parity tests.** (Grouped: both are smaller mechanical refactors of the same shape.)

Each task ends green with the full Core suite passing (behavior byte-identical).
