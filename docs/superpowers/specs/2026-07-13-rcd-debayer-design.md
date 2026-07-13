# RCD Debayer — Design

**Date:** 2026-07-13
**Branch:** `feature/rcd-debayer` (off `main` @ ab6d8fe)
**Status:** approved for planning

## Problem

The stacker demosaics every OSC sub with a mask-normalized 3×3 **bilinear** kernel (`Debayer.bilinear`). Bilinear is exact on smooth sky but soft on point sources: star cores blur across channels and bright stars pick up color fringing, which the stack then bakes in. Registration is unaffected (it uses CFA superpixel luminance), but every accumulated RGB pixel comes from this one call site (`StackEngine.displayRGB`).

## Goal

Add **RCD (Ratio Corrected Demosaicing)** — the astro-community standard (Siril's default; RawTherapee/librtprocess) designed specifically to avoid overshoot and color-fringe artifacts around stars — as a selectable demosaic, **default on**, with the existing bilinear kept as a byte-identical legacy option. Applies wherever subs are demosaiced (live + import, the single `displayRGB` site). Deterministic, row-parallel, zero new dependencies.

## Non-Goals

- No other algorithms (AHD/VNG/LMMSE) — RCD only; the picker leaves room later.
- No change to registration (CFA superpixel luminance path untouched).
- No drizzle / super-resolution.
- No change to mono frames (pass through as today).
- Zero external dependencies; no Metal/Accelerate-specific demosaic (plain Swift, `Parallel.rows`).

## Algorithm (what T1 must pin down)

RCD, per the published reference implementation (Luis Sanz Rodríguez; `librtprocess` `rcd_demosaic`):
1. **Directional discrimination:** local vertical/horizontal gradient statistics on the CFA decide, per pixel, how to blend the V and H green estimates.
2. **Green interpolation at R/B sites:** ratio-corrected directional interpolation (the "ratio" uses a low-pass estimate so the green estimate tracks local luminance ratios instead of raw differences — this is what kills star fringing).
3. **R/B at G and at opposite-color sites:** interpolated via color-difference/ratio in the RCD manner.
4. **Borders:** the outer 4-pixel border uses the existing bilinear result (reference implementations do a simple border fill; reusing our mask-normalized bilinear keeps edges exact and deterministic).

The **Task-1 Python prototype is the normative reference for the port**: it implements RCD faithfully from the published algorithm, validates it beats bilinear, and **exports golden test vectors** (small CFA inputs + expected RGB outputs, all 4 patterns) that the Swift port's tests pin against. Where the prototype makes a documented simplification of the reference, the golden vectors — not prose — define the contract.

## Components

### 1. Prototype — `scratchpad/rcd_debayer.py` (Task 1, not shipped, gate + golden-vector generator)
numpy. (a) Build ground-truth RGB star fields (Gaussian stars of varied intensity incl. near-saturation, on gradient sky + noise); mosaic to CFA per pattern; demosaic with bilinear (port of our Swift kernel) and RCD; measure star-core PSNR / per-channel star FWHM consistency / color-fringe energy (chroma variance in an annulus around stars) / smooth-sky PSNR (must not regress). (b) Sanity-run on one real Seestar sub (`~/Documents/lights`, GRBG 3840×2160): visual PNG crops + channel-consistency stats. (c) Emit `golden vectors`: for each of the 4 patterns, a ~16×16 CFA input and the prototype's RCD output, as Swift-pasteable literals in the report. **Gate:** RCD clearly beats bilinear on star metrics without regressing smooth sky; if not, BLOCKED (do not proceed).

### 2. `Debayer.rcd(cfa:pattern:minRows:)` — `Sources/LiveAstroCore/Stacking/Debayer.swift` (Task 2)
Same signature/shape as `bilinear` (1-channel CFA `AstroImage` in, 3-channel out). Faithful port of the T1 prototype; borders (outer 4 px) delegate to the bilinear result. Row-parallel via `Parallel.rows`; parallel == serial byte-identical; deterministic. TDD anchored on the golden vectors (all 4 patterns) + flat-field exactness (a constant CFA demosaics to the exact constant, interior and borders) + parallel/serial parity + mono/degenerate passthrough guards (width/height < 8 ⇒ fall back to bilinear entirely).

### 3. Selection plumbing + UI (Task 3)
- `public enum DemosaicMethod: String, Codable { case bilinear, rcd }` (LiveAstroCore).
- `SessionSettings.demosaic: DemosaicMethod` — default `.rcd`, backward-compat decode `?? .rcd` (full 5-touch-point pattern + `.defaults`).
- `StackEngine.init(..., demosaic: DemosaicMethod = .bilinear)` — engine default stays `.bilinear` so every existing test/caller is byte-identical (mirrors `frameWeighting`/`normalization`); `displayRGB` switches on it.
- `AppModel.demosaic` persisted + passed in `makeStackEngine()` (app default `.rcd`).
- `ControlView`: "Demosaic" segmented picker (Bilinear | RCD) with ⓘ ("RCD keeps star cores sharp and fringe-free; Bilinear is the legacy demosaic."), disabled while running/importing.
- Perf pin: add an RCD case to the existing release-gated `PerformanceTests` (skips in debug) asserting RCD ≤ 5× bilinear on a 3840×2160 CFA.

## Determinism / Correctness

- `rcd` is pure, per-pixel deterministic, no data-dependent iteration counts; parallel row bands write disjoint outputs (same discipline as `bilinear`/`Warp`).
- Engine `demosaic: .bilinear` (the default) ⇒ **byte-identical** to today (regression-guarded by the entire existing suite).
- Golden-vector parity pins the Swift port to the validated prototype across all 4 patterns.
- Borders exact via the existing mask-normalized bilinear; flat field reproduces exactly everywhere.
- NaN/Inf: inputs are already sanitized at ingest (FITSReader/Calibrator); `rcd` must still not produce non-finite output from finite input (clamp final values to [0,1] like bilinear does).

## Testing

**Prototype (T1):** the gate + golden vectors, as above.
**Core (T2, TDD):** golden-vector parity ×4 patterns; flat-field exactness; parallel==serial; sub-8×8 falls back to bilinear; output finite and in [0,1]; star-sharpness spot check (RCD star core closer to ground truth than bilinear on a synthetic in-Swift case).
**T3:** settings round-trip + backward-compat (`?? .rcd`); engine-default byte-identity (a `StackEngine()` stack unchanged — existing suites); build + full suite; perf pin (release-gated).
**Post-merge manual:** re-import a few NGC 6888 subs and eyeball star tightness vs the previous master.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps; demosaic in plain Swift + `Parallel.rows`.
- Engine default `.bilinear` = byte-identical to today; app default `.rcd`.
- All 4 Bayer patterns; borders via existing bilinear; sub-8×8 frames fall back to bilinear.
- The T1 prototype + its golden vectors are the normative reference for the Swift port.
- Core logic TDD'd; prototype is a validation artifact; app/UI build-verified; adversarial pass before merge (numerical: pattern-phase correctness — a Bayer-phase color bug shipped once before in this project; degenerate: edges/saturation/tiny frames).

## Task Order (for the plan)

1. **T1 — Python prototype + gate + golden vectors.** RCD vs bilinear on synthetic star fields + one real Seestar sub; export golden vectors ×4 patterns.
2. **T2 — `Debayer.rcd` (TDD).** Port pinned to golden vectors; borders, parallelism, degenerate fallbacks.
3. **T3 — `DemosaicMethod` + settings + engine option + picker + perf pin.**
