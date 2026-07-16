# Frame Weighting — Design

**Date:** 2026-07-12
**Branch:** `feature/frame-weighting` (off `main` @ 60ceb9a)
**Status:** approved for planning

## Problem

Every accepted sub contributes equally to the stack. A few poor subs — passing clouds, wind-shake, a light-pollution gradient, poor seeing/focus — drag down the whole result: they add noise and gradient without proportional signal. A quality-weighted combine lets good subs dominate and bad subs contribute less, improving the final image every session, live and on import.

## Goal

Weight each accepted frame's contribution to the stack by a per-frame quality scalar `w_f` combining background noise (inverse-variance) and star count (transparency/focus). The weight scales the frame's mask contribution in the accumulator's existing weighted mean. Applies to the stacking core (the linear master), live and import. Deterministic, zero new dependencies. Default on, with a toggle.

## Non-Goals

- No per-frame background/scale **normalization** (aligning sky level before combine) — separable follow-on; deferred. The accumulator's weighted mean plus the display-path BN/DBE handle residual background.
- No star-FWHM/sharpness term for v1 (star *count* is the transparency proxy; `flux`/FWHM can be a later refinement).
- No change to frame *acceptance* (registration rejection is unchanged) — weighting only scales accepted frames.
- No external dependencies; deterministic math.

## How the weight works

The accumulator already computes a weighted mean: `sum[i] += m[i]·px; weight[i] += m[i]`, `mean = sum/weight`, where `m` is the binary coverage mask. Frame weighting multiplies each frame's mask contribution by a scalar `w_f`:

```
sum[i]    += w_f · m[i] · px[i]
weight[i] += w_f · m[i]
```

This is **incremental and live-correct**: each frame is added once with its own `w_f`; the running weighted mean is exact at every step. Past frames are never re-weighted.

**The weight** (relative to the seed/reference frame for numerical stability + an interpretable clamp; the weighted mean is invariant to a global scale on the weights, so relative == absolute up to that scale):

```
w_f = clamp( (stars_f / stars₀)^p · (σ₀ / σ_f)² ,  wLo,  wHi )
```
- **σ_f** — median background-noise σ of the frame, taken from `StarDetector`'s existing per-cell `sigGrid` (computed during star detection on the half-res luminance — near-free). `(σ₀/σ_f)²` is the inverse-variance term: a noisier/cloudier/gradient-heavier frame has larger σ_f → lower weight.
- **stars_f** — detected star count. `(stars_f/stars₀)^p` is the transparency/focus term: fewer stars (haze, defocus) → lower weight.
- **stars₀, σ₀** — the seed frame's star count and σ, captured when the reference is established (reset on reseed). The seed gets `w = 1`.
- **p, wLo, wHi** — the blend exponent and clamp bounds, **validated by the Task-1 prototype** (starting values `p = 1.0`, `wLo = 0.25`, `wHi = 4.0`). The clamp prevents any single pristine frame from dominating and stops a bad frame from contributing ~0 (which would effectively reject it).

When weighting is OFF, `w_f = 1.0` for every frame → identical to today's equal-weight stack (byte-identical guarantee for the off path).

## Approach: prototype-first

The blend (p, clamps, whether σ² or σ) benefits from empirical validation. Task 1 is a Python prototype on a synthetic sub set (clean subs + deliberately degraded ones: added noise, a gradient, fewer stars, a cloud-dimmed frame). It confirms weighting **improves the stacked SNR / reduces the bad frames' influence** vs equal-weight, and fixes `(p, wLo, wHi)`. Mirrors the DBE v3 prototype-first flow.

## Architecture

### 1. Prototype — `scratchpad/frame_weighting.py` (Task 1, not shipped)
numpy. Generate N synthetic aligned subs of one field: a common star field + independent noise; degrade a subset (extra noise → higher σ, a gradient, dropped stars). Combine equal-weight vs `w_f`-weighted; measure stacked background σ and star SNR. Deliverable: weighted beats equal-weight (lower background σ, higher star SNR), with validated `(p, wLo, wHi)` in the report.

### 2. `StarDetector` — expose the background σ
Add `detectWithStats(luminance:width:height:...) -> (stars: [Star], backgroundSigma: Float)` that reuses the existing `sigGrid` computation and returns the **median** of `sigGrid` as `backgroundSigma`. The existing `detect(...)` remains (delegates to it or vice versa) so current callers/tests are unaffected.

### 3. `StackAccumulator.add(_:mask:frameWeight:minRows:)`
Add a `frameWeight: Float = 1.0` parameter; scale the per-pixel contribution by it (`mv = frameWeight · mask[i]`). Default 1.0 keeps every existing caller byte-identical. Parallel/deterministic as today.

### 4. `StackEngine` — compute and apply `w_f`
- `init(..., frameWeighting: Bool = false)` (mirrors the `rejection` option). When false, `w_f = 1.0` always.
- Seed: capture `stars₀`, `σ₀` (from `detectWithStats`) into stored baseline fields; reset on reseed.
- `RegisteredFrame` gains `weight: Float` — computed in `register` from the frame's `stars_f`, `σ_f`, and the baseline; `commit` passes it to `accumulator.add(..., frameWeight:)`.
- The monolithic `process` (live path) computes `w_f` the same way for its `add`.
- Weight computation is a small pure helper `frameWeight(stars:sigma:) -> Float` on the engine (testable in isolation), using the validated `(p, wLo, wHi)` constants.

### 5. Settings + AppModel + UI (mirror the rejection toggle)
- `AppModel.frameWeightingEnabled = true`; persisted in SessionSettings (codable, backward-compat decode `?? true`).
- `startSession` passes `frameWeighting: frameWeightingEnabled` to `StackEngine.init`.
- `ControlView`: a `Toggle("Weight frames by quality", isOn: $model.frameWeightingEnabled)` next to the existing "Reject outliers (σ-clip)" toggle, with a `.help(...)`.

## Determinism / Correctness

- `frameWeight(stars:sigma:)` is pure; the accumulator scaling is deterministic (no reordering). Weighting ON is reproducible run-to-run.
- Weighting OFF (`w_f = 1.0`) is **byte-identical** to today's stack (regression-guarded).
- σ_f guarded against zero (`σ₀ / max(σ_f, ε)`); stars₀ guarded (`max(stars₀, 1)`); `w_f` clamped to `[wLo, wHi]` → always finite and bounded.
- The seed frame always gets `w = 1` (baseline), so a session always has a well-defined weighted mean.

## Testing

**Prototype (Task 1):** weighted stack beats equal-weight on the synthetic degraded set (lower background σ, higher star SNR); `(p, wLo, wHi)` chosen.

**Core (TDD):**
- `StarDetector.detectWithStats` returns the same stars as `detect` plus a positive `backgroundSigma`; a noisier luminance yields a larger `backgroundSigma`.
- `StackEngine.frameWeight(stars:sigma:)`: seed-equal inputs → 1.0; a noisier frame (larger σ) → lower weight; a starless-vs-many frame → lower weight; clamped to `[wLo, wHi]`; monotonic in each factor.
- `StackAccumulator.add(frameWeight:)`: two frames with weights 2 and 1 → the mean is the 2:1 weighted average (hand-computed); `frameWeight: 1.0` equals the current unweighted add.
- **Off-path parity:** a `StackEngine(frameWeighting: false)` stack over a frame set is byte-identical to the pre-change stack (equal weight).
- **On-path improvement (integration):** with `frameWeighting: true`, a low-quality synthetic frame (high σ / few stars) contributes measurably less than a high-quality one (assert the stack is pulled toward the good frame).

**App/UI:** build/manual-verified — the toggle persists; toggling changes the master; default on.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Stacking-core (linear master) feature — not display-path.
- Deterministic; weighting-off is byte-identical to today.
- Core logic TDD'd; Python prototype is a validation artifact; app/UI build-verified.
- `(p, wLo, wHi)` come from Task 1's validated report (plan starting values: 1.0 / 0.25 / 4.0).

## Task Order (for the plan)

1. **T1 — Python prototype + validation.** Synthetic good/degraded subs; weighted vs equal-weight SNR; output `(p, wLo, wHi)`.
2. **T2 — `StarDetector.detectWithStats` (TDD).** Expose median background σ; existing `detect` unchanged.
3. **T3 — `StackAccumulator.add(frameWeight:)` + `StackEngine.frameWeight` helper + `frameWeighting` option + `RegisteredFrame.weight` wiring (TDD).** The core weighting math + off-path byte-identical parity.
4. **T4 — Settings + AppModel `frameWeightingEnabled` + `ControlView` toggle (TDD settings + build).** Persist + wire + UI.
