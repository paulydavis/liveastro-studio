# Multiplicative Scale Normalization — Design

**Date:** 2026-07-14
**Branch:** `feature/scale-normalization` (off `main` @ 90e4af6)
**Status:** approved for planning

## Problem

Transparency drift (haze, thin cloud, airmass) scales each sub's *signal* by a per-frame factor while the sky background stays additive. The stack currently corrects the additive part (gradient leveling), down-weights noisy subs (frame weighting), but never corrects signal **amplitude**: a hazy sub's stars arrive dimmer and pull the master's signal downward, and σ-clip compares inconsistent amplitudes. Multiplicative normalization scales each sub's signal to the reference before the combine — completing the normalization trio (level = additive, weight = influence, scale = gain).

## Goal

Estimate each accepted sub's transparency factor from the **matched-star flux ratio** registration already produces, scale the sub's signal about the reference background, and combine. Default on ("Match transparency" toggle). Deterministic, zero deps, off = byte-identical, both paths (live + import). Frame weighting sees the post-scale noise.

## Non-Goals

- No photometric calibration (absolute flux) — relative-to-seed only.
- No per-pixel or spatially-varying gain (flat-field's job); one scalar per sub (per session-wide channels — a single luminance-derived factor, not per-channel: transparency is achromatic to first order and per-channel star flux at half-res is noisy).
- No change to frame acceptance; no interaction with DBE/display path.
- Scale is NOT a cloud detector: `s` is clamped to [0.5, 2.0]; worse than that is weighting/rejection's job.

## How it works

### Estimator (near-free, reuses registration)
`register`/`processLocked` already solve the sub→reference transform via RANSAC over `TriangleMatcher` correspondences. After a transform is found, recompute the **inlier pairs** once (`TransformSolver.inliers(...)`, existing internal helper — no signature change) and take:

```
s_f = median( flux_ref / flux_sub  over inlier pairs )      clamped to [0.5, 2.0]
```

- Fluxes come from `StarDetector` on the half-res luminance — sub and reference measured in the same domain, so the ratio is valid.
- Robust: median over RANSAC-vetted pairs; a dimmer (hazy) sub gives `s_f > 1` (scale up to match the reference).
- Guards: fewer than 5 inlier pairs, or any non-finite/≤0 flux in a pair (skip that pair) → `s_f = 1.0` (no scaling). Seed frame: `s = 1.0` by definition.

### Application (signal-only, about the reference background)
Scaling the whole frame would corrupt the background that leveling matches. Scale the *signal* about the reference's per-channel background level:

```
out[c][i] = clamp( bg₀[c] + (x[c][i] − bg₀[c]) · s_f , 0, 1 )
```

- **bg₀[c]** = the seed frame's per-channel background median (`AstroImage.stats[c].median` of the seed rgb — free), stored as `scaleBaseline: [Float]?` at BOTH seed sites and reset at BOTH reseed sites (the `weightBaseline` discipline; cf. the auto-reseed Critical this project shipped once).
- A standalone pure pass (`SignalScaler`), applied **after** `GradientLeveler` and **before** `rejection.apply`, in both paths. Independent of the leveling toggle (a scalar pivot is second-order vs the surface pivot; keeping the passes independent keeps both toggles orthogonal).
- `s_f == 1.0` returns the frame untouched (byte-identical fast path).

### Weighting interaction (scale-then-inverse-variance, done right)
Scaling multiplies the sub's noise by `s_f` too. When scaling is on, the frame weight must use the post-scale noise:

```
w_f = clamp( (stars_f/stars₀)^p · (σ₀ / (σ_f · s_f))² , 0.25, 4.0 )
```

i.e. pass `sigma: σ_f * s_f` to the existing `frameWeight`. A scaled-up hazy sub contributes correct signal amplitude at appropriately reduced weight — the textbook estimator. When scaling is off, weighting is unchanged.

## Approach: prototype-first (the scalar-pedestal lesson applies squarely)

Task 1 validates on synthetic subs with drifting transparency (signal × 0.6…1.0 across the session, constant background, noise, stars):
1. The matched-flux estimator recovers the true factor (|ŝ − s_true| small, robust to noise + a few mismatched pairs).
2. Scale-then-weight beats weight-alone on metrics that actually move: **master star-amplitude error vs ground truth** and σ-clip efficacy (injected streak residual with drifting transparency).
If the win doesn't clearly show, STOP (BLOCKED) — do not build.

## Components

1. **Prototype** — `scratchpad/scale_normalization.py` (T1, gate; not shipped).
2. **`SignalScaler`** — new, `Sources/LiveAstroCore/Stacking/SignalScaler.swift`: `apply(_ image: AstroImage, scale: Float, background: [Float], minRows: Int = 64) -> AstroImage` (pivot per channel, clamp, `scale == 1` fast path, `Parallel.rows`, precondition `background.count == channels`).
3. **`StackEngine`**:
   - `static func scaleFactor(pairs: [(sub: Star, ref: Star)]) -> Float` — pure median-ratio + guards + clamp (constants `scaleLo = 0.5`, `scaleHi = 2.0`, `minScalePairs = 5`).
   - `scaleNormalization: Bool = false` init option (engine default off = byte-identical; app passes the setting).
   - `scaleBaseline: [Float]?` set at both seed sites (`rgb.stats` medians), nil at both reseed sites.
   - `register`: after solving, recompute inliers (`TransformSolver.inliers`), compute `scale = scaleNormalization ? scaleFactor(...) : 1.0`; `RegisteredFrame` gains `scale: Float`; weight computed with `sigma * scale`.
   - `commit(... scale: Float = 1.0 ...)`: apply `SignalScaler` after the leveler, before rejection, when `scale != 1` and `scaleBaseline != nil`. Same insertion in `processLocked`. `BatchImporter.Work` threads `scale`.
4. **Settings/UI** — `SessionSettings.scaleNormalizationEnabled` (default true, `?? true`, full touch-point pattern), `AppModel` + `makeStackEngine(scaleNormalization:)`, `helpToggle("Match transparency", …)` after "Match sky background".

## Determinism / Correctness

- Estimator and scaler pure/deterministic; median over a deterministically ordered pair list.
- Off (`scaleNormalization: false`) ⇒ `scale = 1.0` everywhere ⇒ byte-identical (regression-guarded); `SignalScaler` fast path also byte-identical at `scale == 1`.
- Clamps: `s ∈ [0.5, 2.0]`; output `[0,1]`; non-finite guarded (bad pairs skipped; no-pairs ⇒ 1.0).
- Baseline lifecycle mirrors `weightBaseline` exactly (both seed + both reseed sites — regression-test the auto-reseed path).
- Weight uses `σ · s` only when scaling on.

## Testing

**Prototype (T1):** estimator accuracy + scale-then-weight wins; gate.
**Core (TDD):** `scaleFactor` (exact median on synthetic pairs; dimmer sub ⇒ >1; clamps; <5 pairs ⇒ 1.0; bad-flux pairs skipped); `SignalScaler` (pivot math hand-computed; scale 1 byte-identical; clamp both ends; per-channel pivot independence; parallel == serial); engine (off-path byte-identical; a dimmed synthetic sub's stars restored toward reference amplitude in the master vs off; weight reduced for scaled-up subs — `sigma·s` reaches `frameWeight`; `scaleBaseline` reset on manual + auto reseed).
**App/UI:** build-verified; toggle persists; default on.
**Post-merge:** real-data A/B (3-night NGC 6888 subs likely have real transparency drift).

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps.
- Stacking-core; not display-path. Off = byte-identical. Engine default off; app default on.
- Order: warp → level → **scale** → rejection → weighted add, both paths.
- `s ∈ [0.5, 2.0]`; ≥5 inlier pairs or `s = 1`; seed `s = 1`; baseline lifecycle = weightBaseline discipline.
- Prototype gates the build; adversarial pass before merge.

## Task Order (for the plan)

1. **T1 — prototype + gate.** Estimator accuracy; scale-then-weight wins on master star-amplitude error + σ-clip efficacy.
2. **T2 — `SignalScaler` + `StackEngine.scaleFactor` (TDD).** Pure pieces.
3. **T3 — engine wiring (TDD).** Baseline lifecycle, register/commit/process insertion, weight σ·s, BatchImporter threading, off-path parity.
4. **T4 — settings + toggle.**
