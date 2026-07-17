# Siril Parity Benchmark — Design

## Goal

Add a skipped-by-default XCTest benchmark that runs LiveAstro's production native stacking path on a locally supplied Siril tutorial corpus and compares the resulting master against Siril's `resultat.fit`. The benchmark is evidence-gathering, not a shipped feature.

## Scope

In scope:

- A new `SirilParityTests` test class.
- Local-only dataset discovery via `LIVEASTRO_PARITY_DATASET`.
- Calibration master construction from the corpus' offsets, darks, and flats.
- Production import path: `FolderFrameSource(.importOnce)` → `BatchImporter` → `StackEngine`, with calibration injected through `BatchImporter.prepare`.
- Metrics and a markdown report artifact written outside the repository.
- Conservative pass thresholds that can be recalibrated after the first real run.

Out of scope:

- Checking any corpus files, Siril outputs, crops, or derived image data into git.
- Invoking Siril from the test.
- Changing production stacking behavior to improve parity.
- Public redistribution of the Astrosurf/Siril tutorial corpus or derived image fixtures.

## Dataset Contract

The test reads `LIVEASTRO_PARITY_DATASET`. If it is unset or does not point at a complete corpus, the test calls `XCTSkip` with a diagnostic.

Expected layout:

```text
<dataset>/
  Brutes_180s/*.fit
  Darks_180s/*.fit
  Flats_3s/*.fit
  Offsets_3s/*.fit
  resultat.fit
```

The current local corpus is `/Users/pauldavis/LiveAstroCorpus/siril-m8-asi2600`. This path is not hardcoded in the test.

## Pipeline Under Test

The benchmark builds calibration frames with existing production utilities:

1. `MasterBuilder.combine(..., kind: .bias, bias: nil)` over `Offsets_3s`.
2. `MasterBuilder.combine(..., kind: .dark, bias: nil)` over `Darks_180s`.
3. `MasterBuilder.combine(..., kind: .flat, bias: biasMaster)` over `Flats_3s`.
4. `Calibrator(dark: darkMaster, flat: flatMaster)` is passed to `BatchImporter.run` through `prepare`.
5. Lights are read by `FolderFrameSource(folder: Brutes_180s, mode: .importOnce)`.
6. `BatchImporter` commits into a normal `StackEngine` using the app's default stacking behavior.

This intentionally exercises the same import/registration/calibration/leveling/scaling/rejection/weighting path the app uses. The test does not introduce a special parity-only stacker.

## Metrics

The first benchmark uses robust, inspectable metrics:

- Per-channel Pearson correlation between LiveAstro's master and Siril's `resultat.fit`.
- Per-channel mean absolute error after affine normalization to account for legitimate output scale differences.
- Star count ratio using `StarDetector` on both masters.
- Median matched-star FWHM ratio using a local test helper that estimates half-flux radius around matched centroids.
- Background sigma ratio from `StarDetector.detectWithStats`.

If image dimensions differ, the test fails with an explicit message. If either master has no detectable stars, the test fails because the metrics are not meaningful.

## Thresholds

Initial thresholds are deliberately loose enough to recognize algorithmic differences while catching regressions:

- Minimum per-channel Pearson correlation: `0.83`.
- Maximum affine-normalized mean absolute error: `0.08`.
- Matched-star count ratio: `0.70...1.30`.
- Median FWHM ratio: `0.75...1.35`.
- Background sigma ratio: `0.50...2.25`.

These thresholds are calibrated from the first completed local M8/M20 run: per-channel Pearson `[0.847918, 0.989489, 0.983172]`, affine MAE `[0.005788, 0.000237, 0.000314]`, star count ratio `1.000000`, median FWHM ratio `1.069045`, and background sigma ratio `2.116990`.

The report always records raw values whether the assertions pass or fail. After the first run, thresholds may be tightened or re-centered based on measured output, but only in a follow-up commit with the report values cited.

## Report Artifact

The test writes `parity-report.md` to a temporary run directory and prints that path. The report includes:

- Dataset path.
- Number of calibration and light frames found.
- Accepted/rejected counts.
- Per-channel correlation and error metrics.
- Star/background metrics.
- Thresholds used.

The report is a local artifact and is not tracked by git.

## Testing Strategy

The implementation is TDD:

1. Add a helper-level test that proves the parity harness skips cleanly when `LIVEASTRO_PARITY_DATASET` is unset.
2. Add pure metric helper tests for Pearson correlation, affine-normalized error, and star matching/FWHM estimation using synthetic images.
3. Add the real corpus test, skipped when the env var is absent.
4. Run the real corpus test locally with `LIVEASTRO_PARITY_DATASET=/Users/pauldavis/LiveAstroCorpus/siril-m8-asi2600` to capture first measurements.
5. Run focused parity tests, then full suite and release build before merge.

## Risks and Boundaries

- The first real run may fail thresholds. That is useful evidence, not automatically a product bug. The report becomes the calibration input.
- Siril's `resultat.fit` may encode a different stretch, crop, channel order, or scale than LiveAstro's native master. The affine-normalized metrics reduce scale sensitivity but not semantic mismatches.
- Full 26 MP frames are slow. The test is skipped by default so normal CI/local runs remain fast.
- The corpus licensing rule stands: local testing is fine, but no public fixture or derived image is committed without explicit redistribution permission.
