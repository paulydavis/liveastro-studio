# Per-Sub Gradient Leveling (Local Normalization) — Design

**Date:** 2026-07-12
**Branch:** `feature/gradient-leveling` (off `main`)
**Status:** approved for planning
**Supersedes:** `2026-07-12-background-normalization-design.md` (the additive-scalar version — the Task-1 prototype proved a scalar pedestal has no standalone master benefit; only per-sub *gradient* leveling does).

## Problem

Across a session each sub carries a slightly different sky **gradient** — a moonrise ramp sweeping across the field, light-pollution tilt changing with altitude, transparency drift. Combining subs with differing gradients has three costs: (1) the master shows a residual large-scale gradient that the display-path DBE cannot fully remove, because DBE only models the *average* gradient of the stack, not the per-sub differences; (2) the winsorized σ-clip rejection sees the gradient differences as per-pixel outliers, weakening rejection of real satellite/plane/cosmic-ray streaks; (3) the differences add low-frequency noise to the combine. Aligning each sub's low-order background to a common reference before the combine fixes all three. (An additive per-channel *scalar* pedestal — the earlier design — cannot: a constant offset averages to a flat background either way, verified 0% in prototype.)

## Goal

Before the weighted combine, level each accepted sub — per channel — so its **low-order background surface** matches the reference (seed) sub's, by subtracting the difference of two fitted polynomial models. Reference-matched (not flatten-to-zero), low-order only (degree 1–2), additive. Applies to the stacking core (the linear master), live and import. Deterministic, zero new dependencies. Default on, with a toggle. Off is byte-identical to today's stack.

## Non-Goals

- **No multiplicative scale/gain normalization** — deferred; frame weighting's inverse-variance term already handles transparency.
- **No high-order / multiscale per-sub modeling** — that would eat large-scale nebula per frame. High-order stays a single careful pass on the *master* (the existing display-path `flattenMultiscale`). Per-sub is low-order (degree 1–2) only.
- **No replacement of the display-path DBE** — leveling removes inter-sub gradient *differences*; the master-DBE still removes the reference's residual gradient downstream. Complementary.
- **No flatten-to-zero.** We subtract `(model_f − model₀)`, preserving the reference's gradient. A sub matching the reference is left unchanged.
- **No change to frame acceptance** (registration rejection unchanged).
- No external dependencies; deterministic math.

## How the leveling works

For each accepted sub, per channel `c`:

```
model_f  = fit low-order polynomial background of this sub      (coeff_f[c])
model₀   = the reference (seed) sub's fitted background         (coeff₀[c])  — captured at seed
diff[c]  = coeff_f[c] − coeff₀[c]                               (elementwise; same degree/basis)
surface  = evaluate diff[c] over the frame grid                (a low-order surface)
leveled  = clamp(frame[c] − surface, 0, 1)                      (over the covered region)
```

The difference of two same-degree polynomial surfaces is itself a polynomial with coefficients `coeff_f − coeff₀`, so only **one** surface is evaluated per channel. Because we subtract the *difference*, the reference sub levels to zero change (`model₀ − model₀`), and a sub with the same gradient as the reference is unchanged.

- **The fit** reuses `BackgroundExtraction`'s existing pipeline: tile medians → σ-clip bright (nebula/star) tiles out of the sky set → least-squares normal equations → `solveSymmetric`. Degree 1 (3 coeffs, a plane) or 2 (6 coeffs, a bowl), chosen by the Task-1 prototype (starting value: degree 1).
- **Fit domain:** the **un-warped** sub `reg.rgb` and the un-warped seed (no warp-border zeros to poison tiles). The low-order difference surface is applied to the warped, reference-aligned frame; for the small dithers/rotations of real subs a low-order gradient is warp-approximately-invariant (the prototype confirms the residual is negligible).
- **Graceful fit failure:** if a channel's fit is singular or has too few sky tiles (existing `flatten` guards), that channel's `diff` is treated as zero (passthrough) — never crash, never corrupt. If the **seed** fit fails entirely, `backgroundBaseline = nil` → leveling is off for the session.

When leveling is OFF, no model is fit and nothing is subtracted → identical to today's stack (byte-identical guarantee for the off path). The seed always levels to zero.

## Pipeline order (the key ordering decision)

```
register → warp → LEVEL → rejection.apply → accumulator.add(frameWeight)
```

Leveling runs **before** rejection so σ-clip compares leveled signal (not gradient differences), and **before** the weighted add. It composes with frame weighting (leveling shifts the low-order background; weighting scales contributions — orthogonal) and with the display-path DBE (which runs later, on the master).

## Approach: prototype-first

The degree (1 vs 2), the reference-matched-vs-flatten choice, and the magnitude of the win need empirical validation — and the earlier scalar prototype proved a naïve metric can mislead. Task 1 is a Python prototype on synthetic subs with **differing / moving gradients** (a ramp whose slope drifts across the session), optionally with injected satellite streaks. It measures the stacked master's large-scale non-uniformity (corner-to-corner and row-mean gradient — metrics that ARE sensitive to per-sub gradient differences, unlike the scalar case) and σ-clip outlier removal. Deliverable: reference-matched per-sub leveling beats no-leveling (flatter master, better rejection), the degree is fixed, and it is confirmed to beat the scalar baseline. Gate must pass before T2. Mirrors the DBE v3 / frame-weighting prototype-first flow.

## Architecture

### 1. Prototype — `scratchpad/gradient_leveling.py` (Task 1, not shipped)
numpy. N synthetic aligned subs of one field: common star field + independent noise + a per-sub linear/quadratic gradient whose slope drifts across the session (moonrise sweep); a subset gets a bright streak. Combine (weighted or equal, σ-clip on) with and without reference-matched per-sub polynomial leveling. Measure: master corner-to-corner background delta, row-mean gradient RMS, and residual streak energy. Deliverable: leveling wins on master flatness AND rejection; degree (1 vs 2) fixed; confirmed better than the scalar baseline.

### 2. `BackgroundExtraction` refactor — expose a reusable `BackgroundModel`
Refactor (behavior-preserving) `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift` to split `flatten` into:
- `struct BackgroundModel { let degree: Int; let width: Int; let height: Int; let coeffPerChannel: [[Double]?] }` — per-channel polynomial coefficients (nil = channel fit failed / passthrough).
- `static func fitBackground(_ image: AstroImage, degree: Int, tilesPerAxis: Int = 32, kappa: Float = 2.5) -> BackgroundModel` — steps 1–3 of the current `flatten` (tile medians, σ-clip, least-squares solve) per channel.
- `BackgroundModel.evaluateSurface(channel: Int) -> [Float]?` — step 4's surface evaluation for one channel (nil if that channel's coeff is nil).
- `flatten(...)` keeps its exact current signature and output, reimplemented as `fit → per-channel evaluate → subtract surface + re-add pedestal` (regression-guarded byte-identical to the pre-refactor `flatten`).

### 3. `GradientLeveler` — new, `Sources/LiveAstroCore/Stacking/GradientLeveler.swift`
Pure. `apply(_ image: AstroImage, subModel: BackgroundModel, refModel: BackgroundModel, minRows: Int = 64) -> AstroImage` — for each channel with both coeffs present, evaluate the difference surface (`coeff_sub − coeff_ref`) and subtract, clamp `[0,1]`, parallel over row bands. A channel with either coeff nil is passthrough. When the two models are identical (seed vs itself) the result is byte-identical.

### 4. `StackEngine` — capture reference model and apply the leveling
- `init(..., normalization: Bool = false)` (mirrors `frameWeighting`). When false, no fit / no apply.
- Seed: fit and store `backgroundBaseline: BackgroundModel?` from the seed `rgb`; reset to nil at ALL reseed paths (manual `reseed()` + auto-reseed block), exactly like `weightBaseline` (cf. the auto-reseed reset fix in e3a9016).
- `RegisteredFrame` gains `backgroundModel: BackgroundModel?` — fitted in `register` from `reg.rgb` (nil when leveling off).
- `commit` applies `GradientLeveler.apply(image, subModel:, refModel:)` **before** `rejection.apply`, when both `backgroundModel` and `backgroundBaseline` are present; the monolithic `process` (live) does the same before its `rejection.apply`.
- Fit uses the Task-1-validated degree (starting value 1).

### 5. Settings + AppModel + UI (mirror the frame-weighting toggle)
- `AppModel.backgroundNormalizationEnabled = true`; persisted in `SessionSettings` (codable, backward-compat decode `?? true`).
- `makeStackEngine` passes `normalization: backgroundNormalizationEnabled`.
- `ControlView`: a `helpToggle("Match sky background", isOn:…, help:…)` next to "Weight frames by quality" (ⓘ-info-button row helper from 8cc358e).

## Determinism / Correctness

- `fitBackground`, `evaluateSurface`, `GradientLeveler.apply` are pure and deterministic (tile medians order-independent; sanitized NaN/Inf; per-pixel-independent subtract). Leveling ON is reproducible run-to-run.
- Leveling OFF is **byte-identical** to today's stack (regression-guarded). The refactored `flatten` is byte-identical to the pre-refactor `flatten` (regression-guarded).
- Clamp `[0,1]` → always finite/in-range; masked-out pixels are not accumulated regardless.
- Singular/too-few-tiles fit → per-channel passthrough (existing guards); seed fit failure → leveling off for the session.
- Baseline captured under the engine lock at seed; reset at every reseed path.

## Testing

**Prototype (Task 1):** reference-matched per-sub leveling beats no-leveling (flatter master, better σ-clip) and beats the scalar baseline; degree fixed.

**Core (TDD):**
- `BackgroundExtraction.fitBackground` / `evaluateSurface`: a synthetic linear-gradient image fits degree-1 coeffs that reconstruct the gradient (evaluate ≈ input minus constant); a too-few-tiles / singular channel returns nil coeff.
- **Refactor parity:** the reimplemented `flatten` is byte-identical to a captured pre-refactor reference on representative images (guard the refactor).
- `GradientLeveler.apply`: identical sub/ref models → byte-identical; a sub with a known extra tilt vs a flat reference has that tilt removed (residual gradient ≈ 0); nil-coeff channel passthrough; parallel == serial.
- `StackEngine`: reference model captured at seed; a sub whose gradient differs from the reference is leveled toward it before combine (assert the stacked large-scale gradient is reduced vs the off path); off-path byte-identical; baseline reset on manual + auto reseed.

**App/UI:** build/manual-verified — toggle persists; toggling changes the master; default on; ⓘ shows the help.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Stacking-core (linear master) feature — not display-path. Reuse (don't duplicate) `BackgroundExtraction`'s fit machinery.
- Additive, per-channel, low-order (degree 1–2) only. Reference-matched (subtract `model_f − model₀`), never flatten-to-zero.
- Deterministic; leveling-off is byte-identical to today; the refactored `flatten` is byte-identical to the current `flatten`.
- Leveling runs BEFORE rejection and BEFORE the weighted add; composes with frame weighting and the display-path DBE.
- Core logic TDD'd; Python prototype is a validation artifact; app/UI build-verified.
- The degree comes from Task 1's validated report (starting value: degree 1).

## Task Order (for the plan)

1. **T1 — Python prototype + validation.** Synthetic moving-gradient subs (+ streaks); reference-matched per-sub leveling vs none (and vs scalar); master flatness + σ-clip metrics; fix the degree. Gate must pass.
2. **T2 — `BackgroundExtraction` → `BackgroundModel` refactor (TDD).** Expose `fitBackground` + `evaluateSurface`; reimplement `flatten` on top; byte-identical refactor parity.
3. **T3 — `GradientLeveler` (TDD).** Pure per-channel difference-surface subtract + clamp, parallel; identical-model byte-identical; nil-coeff passthrough.
4. **T4 — `StackEngine` baseline model + `normalization` option + `RegisteredFrame.backgroundModel` + apply-before-rejection in `commit`/`process` (TDD).** Off-path byte-identical; reseed reset.
5. **T5 — Settings + AppModel `backgroundNormalizationEnabled` + `ControlView` toggle (TDD settings + build).** Persist + wire + UI.
