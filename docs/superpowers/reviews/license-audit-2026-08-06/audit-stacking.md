# Copyright/License Audit: LiveAstro Studio (Swift) vs Siril (C, GPLv3)

Date: 2026-08-06
Auditor stance: adversarial — assumed derivation, hunted for fingerprints to refute independence.

Target: `/Users/pauldavis/liveastro-studio/Sources/LiveAstroCore/Stacking/` + `Calibration/`
Reference: `/private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/siril-src/src/stacking/` (all files), `src/core/preprocess.c`, and — added to scope because it is the closest functional analog — `src/livestacking/livestacking.c`.

Method: full read of both sides; targeted grep of the entire Swift package for Siril-specific
identifiers and magic constants (`1.134`, `0.0005`, `1.5f` winsorization bounds, `quickmedian`,
`w_stack`, `o_stack`, `crej`, `siglow/sighigh`, `Winsorize`, `kept`, `N - r <= 4`, "no more
rejections"). Zero hits (the only "Siril" strings in Swift are interop references, see §7).

---

## 1. WinsorizedSigmaClip.swift — verdict: INDEPENDENT

Not merely an independent implementation — it is a *different algorithm* in the same family.

Siril (`rejection_float.c:223-258`, ushort twin `median_and_mean.c:831-866`): batch, per-pixel
stack of ALL frames; iterative Huber winsorization at `median ± 1.5σ` with the published
`sigma = 1.134 * sd(winsorized)` correction and convergence test
`fabsf(sigma - sigma0) > sigma0 * 0.0005f` (rejection_float.c:230-237); then asymmetric
sigma-clip against the median with separate `siglow`/`sighigh` (rejection_float.c:243), pixels
*removed* from the stack, loop `while (changed && N > 3)` with the `N - r <= 4` "no more
rejections" guard (rejection_float.c:238-241).

Swift (`WinsorizedSigmaClip.swift:24-57`): online/streaming; per pixel·channel Welford running
stats (`count`, `mean`, `m2`, lines 53-56 — textbook Welford, no Siril counterpart anywhere);
incoming value *clamped* (never removed) to `mean ± kσ` (single symmetric kappa, line 46-49)
using population σ `sqrt(m2/count)` (Siril uses sample sd with N−1, median_and_mean.c:661);
warm-up gate `count >= warmUp` with a floor of 2 (lines 13-20) that has no analog in Siril;
memory O(image), O(1) in frame count — the opposite memory model from Siril's
all-frames-in-a-block design (median_and_mean.c:46-62 comment describes that design).

Fingerprint check: none of 1.5, 1.134, 0.0005, median-based center, siglow/sighigh asymmetry,
pixel removal, the N>3 / N−r≤4 guards, or Siril's comment phrasing appears in the Swift file.
The default `kappa = 3.0` is the universal textbook sigma-clip default, and the UI mapping
3.5/3.0/2.5 (`RejectionMethod.swift:23-29`) matches nothing in Siril.

## 2. StackAccumulator.swift — verdict: INDEPENDENT

Siril's only accumulator-style code is `sum.c` (`sum_stacking_image_hook`, sum.c:107-237):
integer `guint64` sums (or double for float input) with `#pragma omp atomic` per pixel,
per-frame integer x/y shift arithmetic (no warp, no mask), and a finalize that normalizes by
the *global max* (sum.c:258-343) or, in the drizzle branch only, divides by an accumulated
weight with an explicit `else *tof++ = 0.0f; // avoid division by zero` (sum.c:352-370).

Swift (`StackAccumulator.swift`): Float32 planar `sum` + per-pixel scalar `weight`
(frameWeight·mask) + a *separate* `coverageSum` (Σ raw mask, weight-independent — no Siril
analog at all; it exists to feed `CoverageCrop`, another no-analog file), row-parallel via a
`Parallel.rows` abstraction, mean = sum/weight guarded by `where weight[i] > 0`
(StackAccumulator.swift:51). No max-normalization, no atomic-per-pixel strategy, no drizzle.
"Sum then divide by weight" is the only overlap, and that is the definition of a weighted
mean. Naming (`fsum/fweight` vs `sum/weight/coverageSum`), layout (Siril per-layer pointer
trio vs Swift single planar buffer), and edge handling (write-0 vs skip) all differ.

## 3. StackEngine.swift — verdict: INDEPENDENT

This is the decisive file, and I checked it against BOTH plausible sources:

a) Siril livestacking (`livestacking.c:585-865`): file-system-based. Each new frame is
symlinked/converted into an on-disk sequence, a **2-image sequence** (previous result +
new frame, `create_seq_of_2`, livestacking.c:88-104) is registered with Siril's global
star aligner and re-stacked with the *batch* `stack_mean_with_rejection` using
`NBSTACK_WEIGHT` (the previous result carries its stack count as weight,
livestacking.c:767-795), result saved back to `live_stack_00001.fit`. State lives in files.

b) Siril batch mean stacking (`median_and_mean.c`): divide-and-conquer block decomposition
(stack_compute_parallel_blocks, median_and_mean.c:295-356), per-pixel cross-frame stacks,
rejection then weighted mean (mean_and_reject, median_and_mean.c:956-1099).

Swift StackEngine shares the architecture of neither: in-memory seed-reference model with
triangle matching + RANSAC similarity solve on half-res superpixel luminance
(StackEngine.swift:220-254), online accumulation of warped frames, auto-reseed after N
consecutive registration failures (StackEngine.swift:256-275 — no Siril analog),
polynomial (degree-2) background-surface leveling fit on tile samples with a
matched-domain sub/ref fit (StackEngine.swift:483-510 — Siril normalization is instead
per-layer scalar offset/scale from median/MAD/IKSS statistics, normalization.c:117-131),
and a lock-protected seed/register/commit split for a worker pool.

Constants cross-check (the derivation test): Swift frameWeight = (stars/stars₀)^1 ·
(σ₀/σ)², clamped [0.25, 4] relative to the *seed* (StackEngine.swift:56-58, 173-178).
Siril noise weight = 1/(scale²·bgnoise²) normalized to *population mean 1*
(median_and_mean.c:1111-1135); star-count weight = ((n−min)/(max−min))²
(median_and_mean.c:1184-1229); wFWHM weight (median_and_mean.c:1137-1182). The 1/σ² term
is inverse-variance weighting (physics, not Siril); the surrounding structure, baseline,
normalization, and clamps [0.25,4] match nothing in Siril. Swift transparency scale =
median matched-star flux ratio clamped [0.5, 2] with ≥5 pairs (StackEngine.swift:61-81);
Siril has no flux-ratio scaling at all (its scale comes from image statistics).

## 4. Calibrator.swift — verdict: INDEPENDENT

Siril (`core/preprocess.c:130-158, 327-358`): `imoper(raw, dark, OPER_SUB)`, optional dark
optimization via golden-section search on calibrated-image noise (preprocess.c:91-215 — no
Swift analog), then `siril_fdiv(raw, flat, normalisation)` where `normalisation` is the
*mean* of a central selection of the flat computed at calibration time (preprocess.c:344-349),
plus cosmetic correction / CFA equalization.

Swift (`Calibrator.swift:49-60`): `v -= dark; v /= max(flat, flatFloor)`; clamp result to ≤1,
non-finite → 0; orientation-flip caching for bottom-up lights (no Siril analog — Siril
operates in file row order). The flat is pre-normalized to *median 1* at master-build time
with floor `1/65535` (`MasterBuilder.swift:13, 64-75`), whose comment attributes the choice
to "the Python prototype's clip(flat, 1.0) in ADU space" — a different lineage, different
statistic (median vs central-selection mean), different pipeline stage.

## 5. MasterBuilder.swift — verdict: INDEPENDENT

Straight mean-combine in Double with first-frame-sets-dimensions skip logic, per-frame bias
subtraction for flats, median-1 normalization (MasterBuilder.swift:23-75). Siril master
building goes through the generic sequence stacker (typically median with rejection over
per-pixel cross-frame stacks) — no structural, naming, or constant overlap.

## 6. Adjacent files (spot-checked)

- `CoverageCrop.swift`, `RejectionMethod.swift`: no Siril counterpart exists (Siril crops via
  registration framing; has no pluggable streaming-rejection protocol).
- `Imaging/AutoStretch.swift`: self-describes as "PixInsight STF / Siril autostretch family";
  uses the published MTF formula and the published defaults (target background 0.25, shadows
  clip −2.8, MAD·1.4826). These are the openly published PixInsight STF parameters that Siril
  itself also adopted — algorithm parameters, not implementation fingerprints. The Swift
  implementation (stride-sampled linked luminance, strength factor, black-point pre-clip) does
  not mirror Siril's code. ALGORITHM-CONVERGENT, flagged for completeness only.

## 7. The "Siril" strings in the Swift codebase

Every occurrence (`SessionPipeline.swift:134-141`, `StackFileWatcher.swift:171-188`,
`SessionSettings.swift:79-81`, `Demo/DemoStackGenerator.swift:3`) is *interoperability*: the
app watches Siril's `live_stack.fit` / `live_stack_00001.fit` output files as an input source.
Consuming a GPL program's output files is not derivation of its code, and this history
(app began as a Siril-output viewer, later grew its own native stacker) is consistent with the
structurally alien design of that native stacker.

## Conclusion

I set out to refute independence and could not. Across every audited file there is not one
shared magic constant beyond published-algorithm parameters, no shared identifier, no echoed
comment, no shared edge-case quirk or bug, and — most tellingly — the fundamental
decomposition is opposite (streaming O(1)-in-frames Welford/accumulator design vs Siril's
batch all-frames-per-pixel block design; in-memory engine vs Siril livestacking's
file-sequence-of-2 reuse of the batch stacker).

| Swift file | Verdict |
|---|---|
| StackAccumulator.swift | INDEPENDENT |
| WinsorizedSigmaClip.swift | INDEPENDENT (different algorithm variant; shares only the published Huber-winsorization concept) |
| RejectionMethod.swift | INDEPENDENT |
| StackEngine.swift | INDEPENDENT |
| CoverageCrop.swift | INDEPENDENT (no Siril analog) |
| Calibrator.swift | INDEPENDENT |
| MasterBuilder.swift | INDEPENDENT |
| Imaging/AutoStretch.swift (out of scope, noted) | ALGORITHM-CONVERGENT |

No SUSPICIOUS or DERIVED findings. No GPLv3 contamination evidence in the audited scope.
