# Import Snapshot Downscale — Design

**Date:** 2026-08-17 · **Status:** implemented
**Goal:** Cut per-frame preview/snapshot cost so native import isn't dominated by full-res
display rendering.

## Problem

For every accepted frame, `SessionPipeline.finalizeCommitted` (import path) calls
`displayCGImage(from: mean)` on the full-res 26 MP stacked float image, then
`SnapshotRecorder.save(...)` encodes the result to `snapshots/%04d.png` + `latest.png`. A
60-sub 26 MP M 63 import ran ~13 s/frame (~13 min total).

Those snapshots feed only the **1920×1080 replay** (downscaled regardless) and the on-screen
`latest.png` preview. `master.fit` (the real deliverable) is written separately, full-res.

## Measurement (this drove the approach)

Component costs on a 26 MP frame:

| Step | Time |
|---|---|
| neutralize (additive) | 2.91 s |
| neutralize (multiplicative) | 3.37 s |
| stretch | 0.11 s |
| makeCGImage | 0.07 s |
| downscale 26 MP→2.5K | 0.04 s |
| PNG encode (2.5K) | ~0.5 s |

The bottleneck is the **two per-pixel `neutralize` passes (~6.3 s) inside `displayCGImage`** —
**not** the PNG encode. So capping only the snapshot output resolution (the first attempt) did
**not** speed up import — it cut a step that was already cheap. The fix has to reduce the pixel
count the neutralize/stretch passes run on.

## Change (Approach B)

Downsample the stacked image to **2560 px long edge (2.5K)** *before* `displayCGImage` in the
import path, so `neutralize` + `stretch` run on ~1/6 the pixels. `mean` stays full-res for the
manifest record + stats; `master.fit` is finalized full-res, separately. Live keeps the
full-res display (for zoom/pan) and caps only its snapshot output (below).

Measured result: **~13.4 s → ~6.7 s per frame (2×)**; a 60-sub import ~13 min → ~6.7 min.

## Components

- **`AstroImage.downsampled(maxLongEdge:)`** (`Imaging/AstroImage.swift`) — area-averaging
  downsample (each output pixel = mean of the source pixels mapping to it; single O(pixels)
  pass; anti-aliased). Returns `self` when already within bounds. Stats on the result are cheap
  (existing `computeStats` is stride-sampled, O(1)).
- **`SessionPipeline.finalizeCommitted`** (import path only) — render the preview/snapshot from
  `mean.downsampled(maxLongEdge: SnapshotRecorder.maxSnapshotLongEdge)`; pass the full-res `mean`
  to `recorder.save(linear:)` so the record dims/stats stay full-res. Live (`handleNative`)
  unchanged.
- **`SnapshotRecorder`** (`Session/SnapshotRecorder.swift`) — `maxSnapshotLongEdge = 2560`
  constant, and a `downscaled(_:maxLongEdge:)` cap in `save`. For import the display is already
  2.5K (no-op); for **live** this caps the full-res live snapshot at 2.5K (smaller/faster PNG,
  live view still full-res in memory). Falls back to the original image if a context can't be
  made — a snapshot is never lost.

`ReplayGenerator`, `FrameSelector`, the manifest schema, and `master.fit` are untouched.

## Data flow (import)

```
frame → engine.currentStack() (26 MP float mean)
      → mean.downsampled(2560)  [NEW] → displayCGImage (neutralize/stretch on 4.4M px, ~1s)
      → SnapshotRecorder.save(cgImage: preview, linear: mean)   ← record dims/stats from full-res mean
      → latest.png, %04d.png (2.5K)   → replay 1920×1080 (unchanged)
master.fit finalized full-res, separately (unchanged)
```

## Error handling

Downsample is pure array math; `SnapshotRecorder.downscaled` falls back to the original on
context-creation failure. `SnapshotError.encodeFailed` semantics unchanged.

## Testing

- `AstroImageDownsampleTests` — caps long edge + preserves a constant field and per-channel
  levels (small images / small cap; logic is size-agnostic).
- `SnapshotRecorderTests` — 26 MP CGImage in → 2560 PNG out; record dims stay full-res;
  ≤ cap passes through unchanged.
- Import E2E (manual, real 26 MP M 63) — 60/60, replay renders, ~6.7 s/frame.

## Non-goals

- Core-stacking speed (register/warp ~4.7 s/frame is now the dominant cost — separate Accelerate/Metal pillar).
- Configurable snapshot resolution; changing replay resolution (YAGNI).
