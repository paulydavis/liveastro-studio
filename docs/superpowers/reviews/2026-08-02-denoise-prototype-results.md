# Denoise Prototype Results (Task 1 gate — amended, PASSED)

**Spec:** docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md §3
*as amended 2026-08-02 (owner-approved, spec commit f1ac6ba)*
**Script:** Scripts/prototypes/denoise_prototype.py @ this commit (feature/native-noise-reduction, Task 1)
**Datasets:** ~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit,
              ~/Documents/LiveAstro/2026-07-12-ngc6960/master.fit
(Veil selection: all five `2026-07-1[012]-ngc6960*` masters re-verified present 2026-08-02;
`2026-07-12-ngc6960` chosen as stack-deepest — STACKCNT 46 × 20 s, TOTALEXP 1380 s, the
largest of the two 46-frame stacks. Note: its field is framed on the bright arc/shell
nebula in the session's upper-right quadrant, and the arc profile below crosses that
rim; the shallow `2026-07-11-*` sessions show the classic 6960 broom but at 9–43
frames were rejected by the stack-deepest rule.)
**Filament window:** rows 1600..1700, cols 1405..1480 (verified to cross the lower
rim of the arc: broad nebular ridge peaking at rows ~1648–1660, contrast 0.129,
no pixel in the window above 0.69 — window chosen to exclude bright stars; the
plan's default cols 2000..2100 falls outside this 2029-px-wide master)
**A/B PNGs:** ~/Desktop/denoise-ab/ (outside the repo, for owner eyeballing;
files are `.ppm` — matplotlib was unavailable, the script's PPM fallback was used.
Constants are unchanged from the first run, so the re-run regenerated them
byte-identical.)

## Amendment note

The first gate run (commit 5014d97) FAILED **validly** under the original
whole-field absolute metrics, and its blur-everything upper-bound analysis showed
the failure was metric-structural: M8's darkest-30%-tiles mask is dominated by
static Sagittarius background structure, capping *any* algorithm at +21–30%
against 40%/50% absolute gates. The owner approved a gate amendment (spec commit
`f1ac6ba220dccfa47f00d2c520c279c0ca227152`):

- **Noise metrics** (bg luma sigma, coarse chroma sigma) are measured on the
  **flattest 10% of a 32×32 luma-MAD tile grid** (minimum 20 tiles; per-tile
  sigma, median across tiles; selection fixed on the before-image luma).
- **Effective targets:** bg ≥ min(40%, 0.7 × bound), chroma ≥ min(50%,
  0.7 × bound), where **bound** = the reduction the blur-everything pass (all
  guard/blend weights forced to 1, same radii/passes) attains on those same
  tiles, computed in-script per dataset and strength.
- FWHM ≤ 2% (whole field), filament ≥ 95%, NaN-strict validity (nstars ≥ 10,
  fc0 > 0, non-NaN metrics *and* bounds), and the A/B eyeball including the
  tile-seam check are all **unchanged** — these are the anti-gaming guards.

This re-run used the **same T1-BINDING constants as the first run** (no
re-tuning was needed; the gain re-sweep was not required). The original-metric
gate table and bound analysis are preserved in git history at commit 5014d97.

## Gate table (observed; measured / bound / effective target per noise metric)

| dataset | strength | bgσ before | bgσ after | Δbgσ | bgσ bound | bgσ target | chromaσ before | chromaσ after | Δchromaσ | chromaσ bound | chromaσ target | FWHM before | FWHM after | ΔFWHM | filament before | after | preserved |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M8 | 0.25 | 0.01508 | 0.01238 | +17.9% | +38.7% | +27.1% | 0.01969 | 0.01482 | +24.8% | +55.2% | +38.6% | 10.44 (24★) | 10.42 | 0.19% | nan | nan | nan% |
| M8 | 0.5 | 0.01508 | 0.01016 | +32.6% | +43.2% | +30.3% | 0.01969 | 0.01000 | +49.2% | +57.7% | +40.4% | 10.44 (24★) | 10.40 | 0.35% | nan | nan | nan% |
| M8 | 0.75 | 0.01508 | 0.01016 | +32.6% | +43.2% | +30.3% | 0.01969 | 0.00939 | +52.3% | +60.9% | +42.6% | 10.44 (24★) | 10.40 | 0.35% | nan | nan | nan% |
| M8 | 1.0 | 0.01508 | 0.00996 | +33.9% | +44.8% | +31.4% | 0.01969 | 0.00889 | +54.9% | +61.7% | +43.2% | 10.44 (24★) | 10.38 | 0.49% | nan | nan | nan% |
| Veil | 0.25 | 0.03504 | 0.02552 | +27.2% | +57.8% | +40.0% | 0.03514 | 0.02586 | +26.4% | +68.8% | +48.1% | 12.47 (14★) | 11.45 | 8.21% | 0.1294 | 0.1257 | 97.1% |
| Veil | 0.5 | 0.03504 | 0.01543 | +56.0% | +64.7% | +40.0% | 0.03514 | 0.01701 | +51.6% | +70.1% | +49.1% | 12.47 (14★) | 12.42 | 0.39% | 0.1294 | 0.1236 | 95.5% |
| Veil | 0.75 | 0.03504 | 0.01543 | +56.0% | +64.7% | +40.0% | 0.03514 | 0.01661 | +52.7% | +71.2% | +49.8% | 12.47 (14★) | 12.42 | 0.39% | 0.1294 | 0.1236 | 95.5% |
| Veil | 1.0 | 0.03504 | 0.01429 | +59.2% | +68.2% | +40.0% | 0.03514 | 0.01645 | +53.2% | +71.6% | +50.0% | 12.47 (14★) | 12.33 | 1.09% | 0.1294 | 0.1213 | 93.7% |

Per-metric gate lines at s=0.5 (script output, verbatim):

```
GATE M8 bgσ: measured +32.6% | bound +43.2% | effective target +30.3% | PASS
GATE M8 chromaσ: measured +49.2% | bound +57.7% | effective target +40.4% | PASS
GATE M8 FWHM: measured 0.35% | limit 2.00% | PASS
GATE Veil bgσ: measured +56.0% | bound +64.7% | effective target +40.0% | PASS
GATE Veil chromaσ: measured +51.6% | bound +70.1% | effective target +49.1% | PASS
GATE Veil FWHM: measured 0.39% | limit 2.00% | PASS
GATE Veil filament: preserved 95.5% | limit 95.0% | PASS
```

GATE at strength 0.5: **PASS** (verdict VALID: no NaN gate metric or bound,
nstars 24/14 ≥ 10, fc0 = 0.1294 > 0; exit 0)

On the flattest tiles both datasets clear their effective targets with margin:
M8 bgσ +32.6% vs target +30.3% (bound-capped: 0.7 × 43.2%), M8 chromaσ +49.2%
vs +40.4%; Veil bgσ +56.0% vs the absolute 40% cap, Veil chromaσ +51.6% vs
+49.1%. The whole-field guards hold: ΔFWHM 0.35%/0.39% ≤ 2%, Veil filament
95.5% ≥ 95%.

## VALIDATED CONSTANTS (BINDING — mirror verbatim into Denoiser.K, Task 2)

Identical to the first run's best-observed constants (reached by iterating the
plan's T1-BINDING starting values; the amendment required no further tuning):

| constant | value |
|---|---|
| CHROMA_DOWN | 4 |
| CHROMA_PASSES | 3 |
| chroma_radius(s) | max(1, floor(2.0 + 6.0*s + 0.5)) — half-up, binding convention |
| CHROMA_EDGE_GRAD (display) | 0.25 (spec start 0.08 starved the sky blend: mean weight 0.45 on Veil) |
| CHROMA_EDGE_GRAD_LINEAR | 0.025 (kept at display/10, validated in the linear check below) |
| CHROMA_BLEND_GAIN | 2.0 (from the --sweep-gains grid; ≥2.0 saturates at s=0.5) |
| LUMA_PASSES | 2 |
| luma_radius(s) | max(1, floor(1.0 + 3.0*s + 0.5)) — half-up, binding convention (radius 4–5 at 0.5 pushed filament preservation below the 95% gate: 93.7% / 92.3%) |
| LUMA_RESIDUAL_K | 1.5 (2.5 let star wings through: Veil ΔFWHM 5.94%) |
| LUMA_BLEND_GAIN | 2.0 (from the --sweep-gains grid; ≥2.0 saturates at s=0.5) |
| LUMA_SIGMA_PROTECT_K | 6.0 (3.0 self-protected sky noise: mean protect 0.67→0.83) |
| STRUCTURE_K | 4.0 |
| STRUCTURED_TILE_FLOOR | 0.15 |
| TILES / MAX_TILE_SAMPLES / BACKGROUND_PERCENTILE / MIN_DIM | 32 / 1024 / 20 / 64 |

Metric-definition constants fixed by the amendment (not sweep values, but the
Swift-side gate/golden tooling must use the same definitions):
FLATTEST_FRACTION 0.10, MIN_FLAT_TILES 20, BOUND_FACTOR 0.7,
BG_TARGET_CAP 0.40, CHROMA_TARGET_CAP 0.50.

## Fixture effect-size floors (BINDING for DenoiserTests)

| assertion constant | value | derivation |
|---|---|---|
| s1MinChromaReduction | 0.442 | stage-1-only coarse chroma reduction @0.5 under the amended metric: M8 +49.2%, Veil +51.6%; min minus 5 pt margin |
| s2MinSigmaReduction | 0.276 | stage-2-only flat-tile bg sigma reduction @0.5 under the amended metric: M8 +32.6%, Veil +56.0%; min minus 5 pt margin |

(Stage-only reductions equal the full-run reductions exactly: the opponent
round-trip returns stage-2's luma and stage-1's chroma unchanged — recombine
gives Y' = y2, C1' = c1', C2' = c2' algebraically — so stage 2 never moves the
chroma metric and stage 1 never moves the luma metric. Verified empirically in
the first run via the external monkeypatch driver; the committed script was
not modified.)

## Linear-domain check (amended metric)

Observed linear-domain run on the raw (unstretched) M8 master at 0.5, measured
on the flattest tiles of the raw luma: flat bg sigma reduction +41.7%
(0.000026 → 0.000015), FWHM delta 0.00% (3.54 → 3.54 px, 40 stars) — constant
CHROMA_EDGE_GRAD_LINEAR = 0.025 validated here (spec §2.3 "linear-domain
strength mapping"; stage-2 thresholds are sigma-relative and therefore
domain-free).

## Eyeball A/B notes

Constants unchanged from the first run; the re-run regenerated byte-identical
PPMs, so the first run's eyeball findings stand:

- Veil s=0.5: chroma mottle and luma grain visibly reduced; arc rim, star
  profiles, and faint outer shell intact. No visible rectangular tile seams at
  1/32-frame boundaries in the inspected crops.
- M8 s=1.0: nebulosity, dark lanes, and Bok globules retained (mild softening,
  not crushed); no seams.
- Veil s=0.25 ΔFWHM 8.21% is a measurement artifact of the marginal 14-star
  sample at half-amplitude (FWHM *decreased* 12.47→11.45), not star bloat; at
  the gate strength the delta is 0.39%.
