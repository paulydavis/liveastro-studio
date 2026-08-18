# Import Finalize Throttle — Design

**Date:** 2026-08-17 · **Status:** approved (design), pending spec review
**Goal:** Cut import wall-clock ~2× (and up to ~25× on huge imports) by rendering the per-frame
display/snapshot only on a cadence, instead of once per accepted frame.

## Problem (measured, real 26 MP M63 import, release)

Per-stage per-frame profile: **finalize 1.78 s/frame = 82 % of the serial work** (register 1.22 s
is parallel ×6 → ~0.2 s amortized; commit 0.22 s; consumer-wait 0.07 s → the serial consumer is
NOT starved). `SessionPipeline.finalizeCommitted` runs, for EVERY accepted frame:
`engine.currentStack()` (mean, ~0.10 s) → `downsampled(2560)` (~0.11 s) → `displayCGImage`
(**neutralize additive+multiplicative ~1.1 s** + stretch + makeCGImage) → `recorder.save` (snapshot
PNG ~0.14 s) → `recordSnapshot` + `onUpdate`. This render is **largely wasted**: the replay keeps
only `maxKeyframes` (45) frames, and the live preview needs only periodic updates. On the 1483-frame
M8 all-nighter this per-frame render is the bulk of the ~4-hour import.

## Change — import-only finalize cadence

Render (mean → downsample → neutralize → snapshot → preview) only on a **stride**; every frame still
does the cheap bookkeeping (progress bar, accepted/rejected counts, watchdog progress) so the UI
stays live and honest. **Import mode only** — the live path (frames trickle at ~11 s, per-frame
finalize is fine) is untouched.

### Cadence

At import start `source.totalCount` is known. Compute once:
```
snapshotBudget   = 60                                   // replay keeps 45; 60 gives selection headroom
importFinalizeStride = max(1, Int((Double(totalCount) / Double(snapshotBudget)).rounded()))
```
A committed frame at accepted-ordinal `index` renders iff **`index == 1` (seed) OR
`index % importFinalizeStride == 0`**. Everything else: bookkeeping only.
- 1483-frame import → stride 25 → ~60 renders instead of 1483 (**~25× less finalize work**).
- 60-frame import → stride 1 → unchanged (already ~3 min; nothing to fix).

So it throttles hardest exactly where the pain is (huge imports) and no-ops on small ones.

### Guaranteed final snapshot

`end()` writes `master.fit` (full-res, cropped, additive-neutralized) but renders NO display
snapshot, and the last accepted frame may be a throttled skip. So `end()`, after the import drain
completes, emits **one final render** from the completed stack IF the last accepted frame wasn't
already rendered (`lastRenderedAcceptedIndex < engine.acceptedCount`) → `latest.png` + the last
replay keyframe always reflect the full-depth result. This runs on the drained consumer's thread
directly (not via `withCallbackDelivery`, which coordinates with in-flight consumer callbacks).

### Sparse snapshots are safe

Throttled snapshot filenames become sparse (`0001, 0025, 0050, …`). `ReplayService` enumerates
snapshots from `manifest.snapshots` (the recorded `snapshotFile` paths), NOT by globbing a
contiguous `0001..N` range — so sparse indices just mean fewer, evenly-spaced replay frames.
`frame-summary.csv` / manifest gets ~`snapshotBudget` rows instead of one per accepted frame
(coarser per-frame data — an accepted trade for the ~2×).

## Components (all in `SessionPipeline.swift`)

- **State:** `importFinalizeStride: Int = 1` (1 = every frame; set at import start),
  `snapshotBudget: Int = 60` (internal `var`, a test seam like `importPreviewLongEdge` /
  `importPrimaryTimeout` — tests set it small so a modest frame count throttles), and
  `lastRenderedAcceptedIndex: Int = 0`.
- **`startSources` (import branch):** set `importFinalizeStride` from `source.totalCount` (fallback 1
  when `totalCount` is nil, so a countless source never throttles).
- **`finalizeCommitted`:** always do `noteFrameProgress()`, metadata capture, `processedCount += 1`,
  and `onImportProgress?`. Gate the existing render block (`currentStack` → … → `onUpdate`) behind
  `shouldRenderFinalize(index:)`: live/watcher mode → always true; import mode → `index == 1 || index
  % importFinalizeStride == 0`. On a render, set `lastRenderedAcceptedIndex = index`.
- **`end()`:** after `drainFiniteImportOrThrow()` and before the `master.fit` write, if import mode
  and `lastRenderedAcceptedIndex < engine.acceptedCount`, render one final snapshot from the current
  stack (reusing the same downsample → `displayCGImage` → `recorder.save` → `recordSnapshot` →
  `onUpdate` path, factored into a private helper shared with `finalizeCommitted`).

No change to: the live/watcher path, register/warp/commit, `master.fit` (still full-res, cropped,
neutralized), the neutralize math, or per-frame progress/count reporting.

## Testing

- **Cadence math:** stride = `max(1, round(total/60))` — total 1483 → 25; 60 → 1; 200 → 3; 30 → 1;
  totalCount nil → 1.
- **Throttle:** drive an import of N synthetic frames with a small `snapshotBudget` (inject/override
  so a modest N throttles); assert the number of saved snapshots ≈ ⌈N/stride⌉ (+ seed + final),
  while `processedCount`/`onImportProgress` fired for ALL N.
- **Seed always renders:** frame index 1 produces a snapshot even under throttle.
- **Final snapshot guaranteed:** after `end()`, when the last accepted frame was off-cadence, a
  snapshot for the final stack exists and `latest.png` decodes to it.
- **Live mode unchanged:** a live (non-finite) session renders a snapshot for every committed frame.
- **Master unchanged:** `master.fit` is full-res and independent of the throttle.
- **Replay still generates** from the sparse manifest snapshots (no contiguity assumption).

## Non-goals

- Moving finalize off the consumer thread / parallel finalize (a different approach; not needed —
  throttle alone hits the target).
- Changing the neutralize passes, the master, the replay keyframe algorithm, or the live path.
- Per-frame snapshot granularity during import (explicitly traded away for the speedup).

## Expected result

Import finalize work drops from N× to ~`snapshotBudget`×. On the profiled M63 case the serial floor
falls from ~1.78 s (finalize) + 0.22 s (commit) toward ~0.22 s + amortized-finalize; on a large
import (≫60 frames) wall-clock approaches the register/commit floor — the ~2× (and up to ~25× on
1483-frame imports) the profile predicts. `master.fit` byte-unchanged; replay + `latest.png` reflect
full depth via the guaranteed final render.
