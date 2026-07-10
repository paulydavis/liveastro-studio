# LiveAstro Studio — "Crop-to-Overlap" Design

**Date:** 2026-07-10 · **Status:** approved for planning ·
**Origin:** the ragged partial-coverage edges (grey wedge, bright seam) seen on the NGC 6960 master, and the measured finding that cropping those edges before GraXpert background-extraction gave **+18% flatter background** — the artifact edges bias whole-frame DBE/denoise/deconv, not just the edges.

## 1. Goal

Auto-crop the exported `master.fit` to the fully-covered region, removing the
partial-coverage edges caused by dither / EQ-drift / field-rotation between
subs. This is a **quality-critical preprocessing step** (measured +18% flatter
gradient fit), not cosmetic — it improves every downstream processing pass.

## 2. Core principle (the key decision)

**Crop is an output-stage operation on a COPY of the finished master. The
`StackAccumulator` and the live view are NEVER cropped.** Rationale (settled
2026-07-10 with Paul): during a session the covered region is a moving target
(it grows and shifts as frames dither in), so any live crop chases a changing
box and could hide signal that later frames fill in — and it would resize the
broadcast frame mid-stream. Cropping a copy of the master once, at the end, when
coverage is settled, sidesteps all of that. The stack is safe by construction.

## 3. Coverage source (already exists)

`StackAccumulator.weight: [Float]` is a per-pixel sum of applied mask values.
`Warp.apply` masks are **binary** (1.0 in-footprint / 0.0 out), so `weight[i]`
is exactly *how many frames covered pixel i* — a ready-made coverage map. It is
currently `private` with no accessor. We add a **read-only** accessor; the
accumulation math (the dumb weighted mean) is unchanged.

## 4. Decisions (made 2026-07-10 with Paul)

| Decision | Choice |
|---|---|
| What gets cropped | **The exported `master.fit` only**, from a copy, at write time |
| NOT cropped | The `StackAccumulator`, the live/broadcast display, and the `replay.mp4` + snapshot PNGs (the live-session record stays full-frame) |
| Coverage source | The existing `StackAccumulator.weight` map via a new **read-only** accessor (no accumulation-logic change) |
| Crop shape | **Rectangular** inscribed bounding box (what Siril/DSS/PixInsight produce; what tools expect) |
| Coverage threshold | A pixel is "well-covered" if `coverage ≥ 0.9 × peak` (peak = max coverage); `0.9` is a named constant |
| Rect method | **Inscribed rectangle** via row/column coverage profiles — robust to translation AND field rotation |
| On/off | **Always-on** with a safety guard (no user setting this pillar — YAGNI) |
| Order vs clean-export | **Crop → additive-balance → write** (crop-before-balance is the measured +18% win) |

## 5. Architecture

Three small units in `LiveAstroCore`, wired at one point in the finalize path.

```
LiveAstroCore/
  Stacking/
    StackAccumulator.swift  (+ read-only coverage() accessor)
    StackEngine.swift        (+ currentCoverage() -> [Float]?)
    CoverageCrop.swift       (NEW: pure coverageCropRect(...))
  Imaging/
    AstroImage.swift         (+ cropped(to:) -> AstroImage)
  Pipeline/
    SessionPipeline.swift    (end(): crop master before balance+write)
```

### 5.1 Coverage accessor (read-only)

```swift
// StackAccumulator
public func coverage() -> [Float]   // returns a copy of the per-pixel weight map
```
```swift
// StackEngine
public func currentCoverage() -> [Float]?   // nil if no accumulator (siril/empty)
```
Both are read-only; they change no accumulation behavior. `coverage()` returns a
copy so callers can't mutate accumulator state.

### 5.2 Crop-rect computation (pure, testable)

```swift
public struct CropRect: Equatable { public let x0, y0, x1, y1: Int }  // inclusive bounds

public enum CoverageCrop {
    /// Inscribed rectangle of the well-covered region.
    /// wellCoveredFraction default 0.9; edgeFloor default 0.5.
    public static func rect(coverage: [Float], width: Int, height: Int,
                            wellCoveredFraction: Float = 0.9,
                            edgeFloor: Float = 0.5) -> CropRect?
}
```
Algorithm:
1. `peak = coverage.max()`; if `peak <= 0` → return nil.
2. A pixel is well-covered iff `coverage[i] >= wellCoveredFraction * peak`.
3. For each row, `rowFrac[y]` = fraction of well-covered pixels in that row;
   for each column, `colFrac[x]` likewise.
4. Trim rows from top and bottom while `rowFrac < edgeFloor`; trim columns from
   left and right while `colFrac < edgeFloor`. The surviving `[x0,x1]×[y0,y1]`
   is the inscribed rectangle.
5. If the surviving rect is empty → return nil.

Row/column profiles (rather than the raw thresholded-set bbox) give a clean
inscribed rectangle even under field rotation, where the covered region is a
rotated quad rather than an axis-aligned box.

### 5.3 `AstroImage.cropped(to:)`

```swift
// AstroImage
public func cropped(to rect: CropRect) -> AstroImage
```
Rectangular sub-region copy of the planar, row-major pixel array, per channel.
New `width`/`height`, same `channels` and `sourceIsLinear`; `stats` recompute
via the existing init. Precondition: rect within bounds.

### 5.4 Wiring in `SessionPipeline.end()`

Replace the current master block:
```swift
if let eng = engine, let master0 = eng.currentStack() {
    // Crop to the covered region (a copy; accumulator untouched).
    let master = cropMaster(master0, coverage: eng.currentCoverage())
    let balanced = neutralizeBackground ? AutoStretch.neutralizeBackgroundAdditive(master) : master
    let totalExp = Double(eng.stackFrameCount) * profile.subExposureSeconds
    let data = FITSWriter.float32(width: balanced.width, height: balanced.height,
                                  channels: balanced.channels, pixels: balanced.pixels,
                                  metadata: sourceMetadata, stackCount: eng.acceptedCount,
                                  totalExposureSeconds: totalExp)
    try data.write(to: dir.appendingPathComponent("master.fit"))
}
```
`cropMaster` applies the safety guard (§6) and returns either the cropped copy
or `master0` unchanged. The cropped `width`/`height` flow straight into the FITS
`NAXIS1/2` — no `FITSWriter` change needed.

## 6. Error handling / safety guard

`cropMaster(_ image, coverage:)` returns `image` unchanged (no crop) when:

| Situation | Behavior |
|---|---|
| `coverage == nil` (Siril passthrough / no accumulator) | write full master |
| `CoverageCrop.rect(...)` returns nil (empty / all-zero coverage) | write full master |
| Crop rect == full frame (uniform coverage, no drift) | no-op (equal to full) |
| Crop would remove **> 40%** of total pixels (area guard — a coverage glitch) | write full master, log it |
| Otherwise | write the cropped copy |

The area guard (`cropped_area >= 0.6 * full_area`) prevents a pathological
coverage map from discarding most of the image.

## 7. Data flow

```
[End Session / import complete]
  master0 = engine.currentStack()          // full-frame mean, uncropped
  cov     = engine.currentCoverage()        // StackAccumulator.weight copy (or nil)
  rect    = CoverageCrop.rect(cov, ...)      // inscribed covered rectangle (or nil)
  master  = (guard passes) ? master0.cropped(to: rect) : master0
  balanced = neutralize ? additive(master) : master
  FITSWriter.float32(balanced, metadata, stackCount, totalExp) -> master.fit
// accumulator, live display, replay.mp4, snapshots: all full-frame, untouched
```

## 8. Testing

`swift test --filter LiveAstroCoreTests`

- **`AstroImage.cropped(to:)`** — a known 4×4 (and 3-channel) image cropped to an
  interior rect yields the exact sub-pixels, right dims/channels, per-channel
  correctness; a full-frame rect is identity.
- **`CoverageCrop.rect`** — a synthetic coverage map with a centered high-coverage
  core and low-coverage borders → the expected inner rect; uniform coverage →
  full frame; a tapered/rotated (triangular-corner) map → the inscribed rect
  (excludes the low-coverage corners); all-zero → nil.
- **Accessors** — `StackAccumulator.coverage()` returns the weight map matching
  the masks added; `StackEngine.currentCoverage()` returns it (nil with no
  accumulator).
- **Safety guard** — `cropMaster` writes full when coverage is nil, when the
  rect would keep < 60% area, and is a no-op under uniform coverage.
- **e2e** — a native session over synthetic subs that **drift** (shared stars,
  translational shift between frames so the footprints only partly overlap) →
  the written `master.fit` has **smaller** NAXIS1/2 than the subs, the
  ragged-edge (low-coverage) pixels are gone, and the crop happens **before**
  the additive-balance (assert on the header dims + that a known edge pixel is
  absent). `StackAccumulator` accumulation output for the same frames is
  unchanged from before this pillar (read-accessor-only).

## 9. Non-goals (future builds)

Live/broadcast-frame cropping (deferred to the broadcast/zoom-pan work, where
the frame-stability problem is handled); the pluggable Denoiser/Processor
pillar; live background extraction; a user-facing crop on/off setting; cropping
the replay/snapshots.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Read accessor perceived as violating "StackAccumulator unchanged" | it is read-only and returns a copy; accumulation math is byte-for-byte unchanged; a test asserts the mean output is identical |
| Rotation (alt-az) makes the covered region non-rectangular | inscribed-rectangle via row/col profiles keeps only fully-covered rows/cols; documented that heavy rotation yields a smaller (but clean) crop |
| A bad coverage map crops away real data | 40%-area safety guard + uniform-coverage no-op + nil-coverage passthrough |
| Off-by-one in crop bounds vs planar indexing | explicit `AstroImage.cropped` unit tests on a known small image, inclusive-bounds convention pinned in `CropRect` |
