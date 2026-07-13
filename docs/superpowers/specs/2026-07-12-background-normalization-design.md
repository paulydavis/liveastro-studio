# Background Normalization — Design

**Date:** 2026-07-12
**Branch:** `feature/background-normalization` (off `main` @ d230618)
**Status:** approved for planning

## Problem

Every accepted sub is combined at its own sky-background level. Across a session the sky level drifts — moonrise, a passing gradient, transparency changes, light-pollution color that shifts with altitude. Combining subs that sit at different pedestals has two costs: (1) the winsorized σ-clip rejection sees the level differences as per-pixel outliers rather than comparing signal, weakening rejection; (2) a few high-sky subs bias the weighted mean upward and add gradient without proportional signal. Aligning each sub's sky level to a common reference before the combine fixes both.

## Goal

Before the weighted combine, shift each accepted sub — per channel — so its sky background matches the reference (seed) sub. Additive only (a per-channel pedestal offset); never scales signal or noise. Applies to the stacking core (the linear master), live and import. Deterministic, zero new dependencies. Default on, with a toggle. Off is byte-identical to today's stack.

## Non-Goals

- **No multiplicative scale/gain normalization** (aligning transparency/exposure) — separable follow-on; deferred. Frame weighting's inverse-variance term already down-weights low-transparency subs, so additive background is the focused, non-overlapping complement.
- **No change to the display-path** `neutralizeBackground` (OSC white balance on the master) — that stays; this is a distinct, earlier, per-sub correction on the linear frames.
- **No change to frame acceptance** (registration rejection is unchanged) — normalization only shifts accepted frames.
- **No spatial/gradient modeling per sub** (that is DBE's job on the master) — normalization removes only a per-channel *constant* pedestal, not a gradient.
- No external dependencies; deterministic math.

## How the normalization works

For each accepted sub, per channel `c`:

```
offset[c]  = bg_f[c] − bg₀[c]          // this sub's sky level minus the reference's
normalized = clamp(frame[c] − offset[c], 0, 1)   // over the covered region
```

- **bg_f[c]** — the sub's per-channel sky-background estimate, taken from the **un-warped** RGB `reg.rgb` (no border zeros). The estimator (median vs a low percentile) is chosen by the Task-1 prototype; the median is `AstroImage.stats[c].median`, computed at construction (near-free).
- **bg₀[c]** — the reference (seed) sub's per-channel background, captured when the reference is established (a `backgroundBaseline`, reset on reseed). The seed gets `offset = 0`.
- Subtraction is over the covered region; masked-out border pixels are never accumulated, so shifting them is harmless. Clamp to `[0,1]` keeps values finite and in-range (mirrors `Calibrator`).

When normalization is OFF, `offset[c] = 0` for every sub → identical to today's stack (byte-identical guarantee for the off path).

## Pipeline order (the key ordering decision)

```
register → warp → NORMALIZE → rejection.apply → accumulator.add(frameWeight)
```

Normalization runs **before** rejection so the winsorized σ-clip compares *signal*, not sky-level pedestals, and **before** the weighted add. It composes cleanly with frame weighting: normalization shifts levels (additive), weighting scales contributions (multiplicative on the mask) — orthogonal operations.

## Approach: prototype-first

The estimator choice (median vs low percentile) and the magnitude of the win benefit from empirical validation. Task 1 is a Python prototype on synthetic subs with drifting sky levels plus a moving gradient: combine normalized vs un-normalized and measure background non-uniformity and star SNR. Deliverable: normalized beats un-normalized (lower background non-uniformity, equal-or-higher star SNR), with the estimator fixed. Mirrors the DBE v3 and frame-weighting prototype-first flow.

## Architecture

### 1. Prototype — `scratchpad/background_normalization.py` (Task 1, not shipped)
numpy. Generate N synthetic aligned subs of one field: a common star field + independent noise; give each sub a different sky pedestal (per channel) and a slowly moving gradient. Combine equal/weighted with and without per-channel pedestal normalization; measure stacked background non-uniformity (e.g. corner-to-corner delta, background σ across the frame) and star SNR. Deliverable: normalized wins; estimator (median vs e.g. 25th percentile) fixed in the report.

### 2. `BackgroundNormalizer` — new, `Sources/LiveAstroCore/Stacking/BackgroundNormalizer.swift`
Pure, parallel per-channel subtract + clamp. `apply(_ image: AstroImage, offset: [Float]) -> AstroImage` subtracts `offset[c]` from channel `c` and clamps to `[0,1]`; parallelized over row bands via `Parallel.rows` (like `Warp`/`Debayer`). `offset == all-zero` returns the frame untouched (byte-identical). `offset.count` must equal `image.channels` (precondition).

### 3. `StackEngine` — capture baseline and apply the offset
- `init(..., normalization: Bool = false)` (mirrors `frameWeighting`). When false, offset is always zero.
- Seed: capture `bg₀[c]` per channel (from the seed `rgb`'s estimator) into a stored `backgroundBaseline: [Float]?`; reset to nil at all reseed paths (manual + auto-reseed), exactly like `weightBaseline`.
- `backgroundOffset(for rgb: AstroImage) -> [Float]` — pure helper returning `estimator(rgb)[c] − baseline[c]`, or all-zeros when normalization is off or before seeding.
- `RegisteredFrame` gains `backgroundOffset: [Float]` — computed in `register` from `reg.rgb`; `commit` applies `BackgroundNormalizer` **before** `rejection.apply`.
- The monolithic `process` (live path) applies the same normalization before its `rejection.apply`/`add`.
- The estimator is a small pure function on the engine (e.g. `perChannelBackground(_ rgb:) -> [Float]`), using the Task-1-validated choice (median or percentile), testable in isolation.

### 4. Settings + AppModel + UI (mirror the frame-weighting toggle)
- `AppModel.backgroundNormalizationEnabled = true`; persisted in `SessionSettings` (codable, backward-compat decode `?? true`).
- `startSession`/`makeStackEngine` passes `normalization: backgroundNormalizationEnabled` to `StackEngine.init`.
- `ControlView`: a `helpToggle("Match sky background", isOn: $model.backgroundNormalizationEnabled, help: "…")` next to "Weight frames by quality" (uses the ⓘ-info-button row helper shipped in 8cc358e).

## Determinism / Correctness

- `perChannelBackground` and `backgroundOffset` are pure; `BackgroundNormalizer.apply` is deterministic (per-pixel independent, no reordering). Normalization ON is reproducible run-to-run.
- Normalization OFF (`offset = 0`) is **byte-identical** to today's stack (regression-guarded).
- Clamp to `[0,1]` → always finite and in-range; masked-out pixels are not accumulated regardless.
- The seed always gets `offset = 0`, so a session always has a well-defined reference level.
- Baseline captured under the engine lock at seed; reset at every reseed path (manual + auto) — same discipline as `weightBaseline` (cf. the auto-reseed `rejection.reset()` fix in e3a9016).

## Testing

**Prototype (Task 1):** normalized beats un-normalized on the synthetic drifting-sky set (lower background non-uniformity, equal-or-higher star SNR); estimator chosen.

**Core (TDD):**
- `BackgroundNormalizer.apply`: subtracts the given per-channel offset and clamps `[0,1]`; `offset = [0,0,0]` is byte-identical to the input; per-channel independence (only channel c shifts for a c-only offset); parallel result equals serial.
- `StackEngine.perChannelBackground`: returns one value per channel; a brighter-sky frame yields a larger background.
- `StackEngine.backgroundOffset`: seed-equal input → zeros; a higher-sky frame → positive offsets; off / before-seed → zeros.
- **Off-path parity:** `StackEngine(normalization: false)` over a frame set is byte-identical to the pre-change stack.
- **On-path improvement (integration):** with `normalization: true`, a high-sky-pedestal sub is pulled to the reference level before combine (assert the stacked background is not biased upward by it, vs the off path).
- **Reseed:** baseline is reset on manual and auto reseed (a new field's seed re-establishes bg₀; mirror the rejection-reset regression test).

**App/UI:** build/manual-verified — the toggle persists; toggling changes the master; default on; ⓘ info button shows the help.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Stacking-core (linear master) feature — not display-path.
- Deterministic; normalization-off is byte-identical to today.
- Core logic TDD'd; Python prototype is a validation artifact; app/UI build-verified.
- The estimator (median vs percentile) comes from Task 1's validated report.
- Normalization runs BEFORE rejection and BEFORE the weighted add; composes with frame weighting.

## Task Order (for the plan)

1. **T1 — Python prototype + validation.** Synthetic drifting-sky subs; normalized vs un-normalized background non-uniformity + SNR; fix the estimator (median vs percentile).
2. **T2 — `BackgroundNormalizer` (TDD).** Pure per-channel subtract + clamp, parallel; zero-offset byte-identical.
3. **T3 — `StackEngine` baseline + `perChannelBackground` + `backgroundOffset` + `normalization` option + `RegisteredFrame.backgroundOffset` wiring + apply-before-rejection in `commit`/`process` (TDD).** Off-path byte-identical parity; reseed reset.
4. **T4 — Settings + AppModel `backgroundNormalizationEnabled` + `ControlView` toggle (TDD settings + build).** Persist + wire + UI.
