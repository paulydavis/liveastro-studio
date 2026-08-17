# Import Snapshot Downscale — Design

**Date:** 2026-08-17 · **Status:** approved (design), pending spec review
**Goal:** Cut per-frame snapshot cost so native import (and live) isn't dominated by full-res PNG encoding.

## Problem

For every accepted frame, `SessionPipeline` calls `displayCGImage(from: mean)` (a full-res
26 MP post-stretch image) and `SnapshotRecorder.save(...)` encodes it to `snapshots/%04d.png`
(~63 MB) and `latest.png`. On a 26 MP ASI2600 frame that PNG encode is ~7 s — the dominant
cost of a batch import (a 60-sub M 63 import runs ~13 min, of which ~7 min is snapshot
encoding).

Those snapshots feed only two things:
- The **replay video**, rendered by `ReplayGenerator` at a fixed **1920×1080** — it downscales
  the keyframes regardless.
- **`latest.png`** — the on-screen / OBS preview.

`master.fit` (the real deliverable) is written separately at full 26 MP and is untouched.
The manifest stats come from the `linear: AstroImage`, not the PNG. The live in-memory view
(`AppModel.latestImage`, which supports zoom/pan) is the `displayCGImage` output, not the PNG.

So encoding snapshots at full 26 MP is wasted work: the replay is 1080p and the preview
doesn't need 26 MP.

## Change

Downscale the snapshot image to **2560 px on its long edge** (≈2.5K) inside
`SnapshotRecorder.save`, before PNG-encoding. 2.5K is 2× the replay's 1080p (so replay output
is byte-for-identical after its own downscale) and stays crisp as a preview on 4K/5K displays.

**Applies to both live and import** — one code path in `SnapshotRecorder`, no mode flag. Live
is not bottlenecked (one frame per ~10–35 s cadence) but benefits from smaller/faster snapshots,
and its on-screen quality is unchanged because the live view uses the full-res in-memory image,
not the PNG.

### Approach (chosen: A)

Downscale in `SnapshotRecorder.save`, keeping `displayCGImage` full-res so the in-memory live
view and its zoom/pan keep full resolution. The recorder is the single choke point that writes
both `%04d.png` and `latest.png`, so one change covers both.

(Approach B — render the display image directly at 2.5K for snapshots — would also skip building
the 26 MP CGImage, a further ~1.5 s/frame, but needs two render paths. Deferred: the core
stacking (~4.7 s/frame) dominates once the encode is cut, so B's extra saving is marginal.
Revisit only if measurement shows the 26 MP CGImage build is itself a large share.)

## Components

- **`SnapshotRecorder`** (`Sources/LiveAstroCore/Session/SnapshotRecorder.swift`)
  - New internal helper `downscaled(_ image: CGImage, maxLongEdge: Int) -> CGImage`: if
    `max(width, height) <= maxLongEdge` return the image unchanged; else draw it into a
    `CGContext` sized to the scaled dimensions (aspect-preserving, `interpolationQuality =
    .high`) and return the result.
  - `save(...)` downscales `cgImage` once (long edge 2560) and encodes the result to both the
    numbered snapshot and `latest.png`. The `linear: AstroImage` argument (stats source) and
    the returned `SnapshotRecord.width/height` are **unchanged** — those keep reporting the
    true stacked dimensions from `linear`, not the downscaled preview.
  - `maxSnapshotLongEdge = 2560` as a named constant with a comment (2× the 1080p replay).

Nothing else changes: `SessionPipeline`, `ReplayGenerator`, `FrameSelector`, the manifest
schema, and `master.fit` writing are all untouched.

## Data flow (unchanged except the resize)

```
frame → engine.currentStack() (26 MP float mean)
      → displayCGImage  → AppModel.latestImage   (full-res, live view + zoom)   [unchanged]
                        → SnapshotRecorder.save
                              → downscaled to 2560px          [NEW]
                              → %04d.png, latest.png          (now 2.5K)
      → recorder.save also records width/height from `linear` (full-res)        [unchanged]
replay: FrameSelector picks keyframes → ReplayGenerator renders 1920×1080       [unchanged]
```

## Error handling

The downscale is a pure CoreGraphics context draw. If context creation fails (should not for
valid dimensions), fall back to encoding the original image — a snapshot must never be lost.
Existing `SnapshotError.encodeFailed` semantics are unchanged.

## Testing

- **Unit (SnapshotRecorder):** save a 6248×4176 CGImage → the written `%04d.png` decodes to
  2560×1712 (long edge 2560, aspect preserved), and the `SnapshotRecord.width/height` still
  report the `linear` dimensions (6248×4176).
- **Unit (passthrough):** a 1920×1280 image is written unchanged (≤ 2560, no resize).
- **Regression:** existing SnapshotRecorder / pipeline / replay tests stay green (replay reads
  a 2.5K keyframe and still renders 1080p).

## Non-goals

- Core-stacking speed (register/warp on Accelerate/Metal) — the larger remaining lever, separate pillar.
- Changing replay resolution or making snapshot resolution configurable (YAGNI).
- Skipping/throttling snapshots per-frame (rejected in favor of the downscale).

## Expected result

Snapshot encode ~7 s → ~0.5 s/frame. Per-frame import ~13 s → ~6 s; a 60-sub import ~13 min →
~5–6 min (~2–2.5×). Replay output unchanged; preview crisp; `master.fit` full 26 MP.
