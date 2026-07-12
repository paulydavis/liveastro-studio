# DBE v3 — Multiscale Background Extraction — Design

**Date:** 2026-07-12
**Branch:** `feature/dbe-v3-multiscale` (off `main` @ e9d29fd)
**Status:** approved for planning

## Problem

LiveAstro's background extraction (`BackgroundExtraction.flatten`) fits a per-channel degree-1/2 polynomial to sky-tile medians and subtracts it. A low-order polynomial models only a smooth ramp/bowl, so it flattens global gradients but leaves **local/patchy residual gradients** — most visibly the residual corner gradient on wide-field / light-polluted frames (the known v3 gap, e.g. on the IC443 master after additive background neutralization). Siril's community "Auto Gradient Removal" script (Cyril Richard) solves exactly this with a **multiscale** model that follows local variations; its polynomial mode is only a fallback for nebula-fills-frame. Our current DBE *is* that fallback shipped as the whole feature.

## Goal

Add a **multiscale background model** as the primary DBE: a spatially-varying, structure-protected, iterative smoothed-background surface with two user knobs (**Scale**, **Smoothest**) that removes local/corner gradients the polynomial cannot. Keep the existing polynomial as an automatic fallback when structure fills the frame. Display-path only (the linear master is never modified), deterministic, zero new dependencies.

## Non-Goals

- No **divide** mode (multiplicative/vignette) — subtract (additive light pollution) is the common case; defer.
- No structure-protection sliders — auto defaults (validated by the prototype).
- No DBE on the **linear master** — display-path only, same as today.
- No per-frame multithreading of the model — the blurs are Accelerate-backed; threading can come later.
- No AI — deterministic math only (matches the source script and LiveAstro's ethos).

## Approach: prototype-first, then port

The multiscale algorithm's exact recipe (iterate/reject/inpaint/smooth) and default parameters are not published beyond the knob *semantics*, so there is genuine algorithm-design risk. Task 1 is a **Python prototype** that validates the recipe and produces the concrete default parameters the Swift tasks consume — mirroring how additive-BN was Python-validated then Swift-ported. No Swift is written until the prototype shows the multiscale model beats the current polynomial on real data.

## Algorithm (to be validated + parameterized by the prototype)

Per channel, on the linear display-space image:

1. **Downsample** by a factor `D` (~4) for speed; the model is upsampled back at the end. Downsampling does not change the background scale (it is smooth).
2. **Iterate** (to convergence or a fixed max iterations):
   a. **Smooth** the current estimate at the **Scale** radius — a large blur whose radius = `Scale` % of the (downsampled) image dimension. Lower Scale → follows smaller/local variations; higher → only broad gradients.
   b. **Reject structure**: flag pixels whose value exceeds the smoothed surface by more than `k·σ` (stars, nebula, galaxy cores) → structure mask; **grow** the mask by a small radius to cover halos/wings.
   c. **Inpaint**: replace masked pixels with the smoothed value so structure does not pull the background up.
   d. Repeat until the mask/model converges (or max iters).
3. **Smoothest**: a final blur pass on the converged model (strength = `Smoothest`), to remove residual blotchiness.
4. **Upsample** the model to full resolution.
5. **Subtract** with a clamp-safe pedestal re-add: `out = clamp(image − model + pedestal, 0, 1)` where `pedestal = min(model)` — the same pattern `flatten` already uses, so blacks are not crushed.

**Auto-fallback to polynomial:** if the structure mask covers more than a threshold fraction of the frame (nebula fills it → too little sky for a multiscale fit), defer to the existing `flatten` (polynomial). This is the source script's "Simplified Model" guidance.

Structure-protection defaults (`k`, grow radius, fallback fraction, `D`, max iters) are fixed constants set from the prototype's validation, documented with the values.

## Knobs

- **Scale** — smoothing radius as a fraction of image size. Range/default from the prototype (video default ≈ 5%, dropped to ≈ 2% for the hard case).
- **Smoothest** — final model blur strength. Range/default from the prototype (video default ≈ 1, dropped to ≈ 0.2 for the hard case).

Both are re-applied live via the existing throttled display re-render, exactly like the other display-adjustment sliders.

## Architecture

### 1. Prototype — `scratchpad/dbe_multiscale.py` (Task 1, not shipped)

numpy/scipy. Loads the IC443 calibrated master (present in the session scratchpad) and a synthetic complex-gradient fixture (a smooth base + a strong local corner gradient + injected "stars"/a "nebula" blob). Runs: current-poly-equivalent vs multiscale; measures a **residual-flatness metric** (background spread over central sky regions, and corner-vs-center background delta) before/after; writes before/after PNGs and a metrics table. Deliverable: the multiscale model measurably flattens the IC443 corner gradient and the synthetic hard gradient better than the polynomial, with a documented default `(Scale, Smoothest, k, grow, fallbackFraction, D, maxIters)`.

### 2. Swift core — `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift` (extend)

```swift
public static func flattenMultiscale(_ image: AstroImage,
                                     scale: Double, smoothest: Double) -> AstroImage
```
- Foundation / CoreGraphics / Accelerate only (blurs via vImage box/Gaussian or Accelerate).
- 3-channel guard + mono passthrough (like `flatten`); sanitizes non-finite inputs to 0 up front (the ingest pattern).
- Deterministic (no undefined-order ops).
- Auto-fallback: when the structure mask fraction exceeds the constant, `return flatten(image, degree: 2)`.

### 3. Wiring — `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`

In `displayCGImage`, when `adj.backgroundExtraction` is on, call `flattenMultiscale(linear, scale: adj.bgScale, smoothest: adj.bgSmoothest)` instead of `flatten(linear, degree: adj.backgroundDegree)`. Same placement (DBE first, on linear data; then the existing neutralize/stretch/saturation path).

### 4. Settings — `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`

Add `public var bgScale: Double` and `public var bgSmoothest: Double` (with neutral defaults = the validated defaults). Codable backward-compat: `decodeIfPresent … ?? default`; keep `backgroundExtraction: Bool`; keep decoding `backgroundDegree` for old-settings compatibility but it no longer drives the UI (the poly fallback uses a fixed internal degree). Mirror the existing `processorBackend`/`displayAdjustments` codable pattern.

### 5. UI — `Sources/LiveAstroStudio/ControlView.swift`

Under the existing **Background Extraction** toggle, replace the degree control with two sliders — **Scale** and **Smoothest** — bound to `$model.displayAdjustments.bgScale` / `.bgSmoothest`, with `.help(...)` tooltips, matching the existing display-adjustment slider idioms + throttled re-render.

## Error Handling

- Non-3-channel → passthrough (mono). Non-finite inputs sanitized to 0.
- Degenerate/too-small images → passthrough (guard like `flatten`).
- Structure fills frame → polynomial fallback (never returns a starved/negative model).
- All clamp-safe: output stays in [0,1] with the pedestal re-add.

## Testing

**Prototype (Task 1):** the residual-flatness metric improves vs polynomial on IC443 + synthetic hard gradient; before/after PNGs reviewed; defaults chosen. Validation artifact, not shipped (lives in scratchpad + a short note in the spec/plan).

**Swift core (TDD, `Tests/LiveAstroCoreTests/BackgroundExtractionMultiscaleTests.swift`):**
- Planar + a **local corner** gradient removed: `skySpread`/corner-delta after < before·0.1 (the poly-failing case the current `flatten` test cannot pass).
- Flat image unchanged within tolerance.
- Bright Gaussian blob preserved (peak − local-sky stays high — signal not eaten by the model).
- Structure-fills-frame → falls back to polynomial (assert equals `flatten(_, degree: 2)` output).
- Mono passthrough; NaN/Inf input → all-finite output.
- Determinism: two runs byte-identical.

**App/UI:** build/manual-verified — toggle on, drag Scale/Smoothest, confirm live corner-gradient removal on a real frame; settings persist.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Display-path only; the linear master is never modified.
- Deterministic; sanitizes non-finite inputs (ingest pattern).
- Core logic TDD'd (`swift test --filter LiveAstroCoreTests`); Python prototype is a validation artifact; app/UI build-verified.
- Multiscale is primary; polynomial `flatten` retained as the auto fallback (not deleted).

## Task Order (for the plan)

1. **T1 — Python prototype + validation.** `scratchpad/dbe_multiscale.py` on IC443 + synthetic hard gradient vs polynomial; residual-flatness metric + before/after PNGs; **output the validated default params** `(Scale, Smoothest, k, grow, fallbackFraction, D, maxIters)` in the task report. Gate: multiscale beats polynomial on the corner gradient.
2. **T2 — Swift `flattenMultiscale` (TDD).** Port the validated recipe (Accelerate blurs, iterate/reject/inpaint/smooth, pedestal subtract, poly fallback); the tests above. Uses T1's validated constants.
3. **T3 — `DisplayAdjustments` fields + `SessionPipeline` wiring (TDD + build).** Add `bgScale`/`bgSmoothest` (codable backward-compat); route `displayCGImage` DBE through `flattenMultiscale`.
4. **T4 — ControlView Scale/Smoothest sliders (build/manual-verified).** Replace the degree control; live re-render; persistence.
