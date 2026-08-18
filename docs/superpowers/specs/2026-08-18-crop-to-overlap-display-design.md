# Crop-to-Overlap for the Display — Design

**Date:** 2026-08-18 · **Status:** approved (design), pending spec review
**Goal:** Apply the coverage crop that already trims `master.fit` to the live/import DISPLAY path,
so the broadcast, snapshots, `latest.png`, and replay show the clean well-covered region instead
of the ragged partial-coverage edges (the grey wedge + bright seam seen on the Veil night).

## Problem

`SessionPipeline.cropMaster` already crops `master.fit` to the well-covered region
(`CoverageCrop.rect` on the accumulator's coverage map). But the per-frame DISPLAY render
(`displayCGImage` fed from `engine.currentStack()`) is NOT cropped, so the live broadcast and every
snapshot/replay frame show the full union of frame footprints — including the dither/drift edge
strips covered by only some frames (visibly darker/brighter). The master is clean; the live view is
not (not WYSIWYG).

## Change

Crop the stacked mean to its coverage rect in the display path, **before** downsample/stretch, using
the SAME logic and defaults the master already uses. Always-on (matches the master; no new UI).

### Components (all in `SessionPipeline.swift` + one small `StackEngine` accessor)

1. **`StackEngine.currentStackAndCoverage() -> (image: AstroImage, coverage: [Float]?)?`** — returns
   the current mean AND coverage under ONE lock acquisition, so the crop rect is computed from a
   coverage map consistent with the mean (avoids a two-`lock` read where a frame could commit
   between `currentStack()` and `currentCoverage()`). Returns nil when there is no active stack.

2. **Rename `cropMaster` → `cropToCoverage`** (it is a pure geometric crop, not master-specific;
   used by both the master and now the display). Behavior unchanged — keep its existing guards:
   full-frame rect → no-op; a rect that would remove >40% of area → keep the full frame + log
   ("Crop-to-overlap: … keeping full frame"). Update its two existing callers (the `master.fit`
   write and the master-snapshot writer). No logic change to the master path.

3. **Crop the display in both render sites:**
   - `renderSnapshot` (import): replace `guard let mean = engine.currentStack()` with
     `guard let (mean0, cov) = engine.currentStackAndCoverage()`, then
     `let mean = cropToCoverage(mean0, coverage: cov)`, and use that cropped `mean` for BOTH
     `displayCGImage` and `recorder.save(linear:)`.
   - `handleNative` (live, `.becameReference`/`.stacked`): the same substitution.

   Cropping `linear` too means the manifest record's dims + stats come from the cropped region,
   consistent with the cropped snapshot PNG and the cropped master. The FrameSelector cloud gate
   (v1.1) compares background medians frame-to-frame; a consistent crop preserves that relative
   comparison and gives cleaner stats (excludes the ragged low-coverage edges). The >40% guard keeps
   early frames full-frame, so the crop engages once coverage stabilizes — a single gradual
   transition, not per-frame jitter.

### The >40% guard handles the lifecycle

Early in a session (few frames, small/uneven coverage) the inscribed well-covered rect can be tiny;
the existing `cropToCoverage` >40%-removed guard returns the full frame in that case, so the display
stays full until the covered region is ≥60% of the frame. From then on it crops to the settling
well-covered region — matching what the final `master.fit` will be.

### Untouched

- `master.fit` (already cropped — only the helper's NAME changes, not its use there).
- The register/warp/commit pipeline, the finalize throttle, the display adjustments/DBE/denoise
  stages inside `displayCGImage`, and `engine` stacking math.
- Mono/degenerate/`nil`-coverage cases → `cropToCoverage` returns the full image (no crash).
- Interaction with zoom/pan: the crop produces the CGImage; zoom/pan operates on it afterward.

## Testing

- **`currentStackAndCoverage`:** returns mean + coverage atomically; nil with no active stack;
  coverage length == width·height.
- **`cropToCoverage` (renamed, behavior pinned):** a ragged synthetic coverage map yields the
  inscribed well-covered rect; a uniform map → full frame (no-op); a map whose well-covered rect
  is <60% area → full frame + the log line; `nil` coverage → full frame. (Reuse/rename any existing
  cropMaster tests.)
- **Import display crop:** an import whose stack has a ragged coverage map produces a snapshot whose
  dims equal the master's crop rect (smaller than the full stack), and `latest.png` decodes to it.
- **Live display crop:** a live (`.stacked`) render with ragged coverage produces a cropped snapshot;
  a uniform-coverage render produces a full-frame snapshot (guard).
- **Master unchanged:** `master.fit` dims identical to before the rename (regression).

## Non-goals

- A user toggle for cropped-vs-union live view (always-on, matching the master — YAGNI).
- Changing `CoverageCrop`'s algorithm or thresholds (`wellCoveredFraction: 0.9`, the >40% guard).
- Holding a fixed crop rect across the whole session (crop tracks current coverage; the guard makes
  the transition gradual).
- Any change to `master.fit`, the stacking math, or the replay keyframe algorithm.

## Expected result

The broadcast, snapshots, `latest.png`, and replay show the same clean well-covered region as
`master.fit` — the grey wedge / bright seam gone — using the crop infrastructure that already
exists. Always-on, WYSIWYG with the master, no new UI.
