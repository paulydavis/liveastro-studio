# Denoise Prototype Results (Task 1 gate)

**Spec:** docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md §3
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
files are `.ppm` — matplotlib was unavailable, the script's PPM fallback was used)

## Gate table (observed)

| dataset | strength | bgσ before | bgσ after | Δbgσ | chromaσ before | chromaσ after | Δchromaσ | FWHM before | FWHM after | ΔFWHM | filament before | after | preserved |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M8 | 0.25 | 0.02379 | 0.02121 | +10.8% | 0.03979 | 0.03591 | +9.8% | 10.44 (24★) | 10.42 | 0.19% | nan | nan | nan% |
| M8 | 0.5 | 0.02379 | 0.01971 | +17.1% | 0.03979 | 0.03285 | +17.5% | 10.44 (24★) | 10.40 | 0.35% | nan | nan | nan% |
| M8 | 0.75 | 0.02379 | 0.01971 | +17.1% | 0.03979 | 0.03226 | +18.9% | 10.44 (24★) | 10.40 | 0.35% | nan | nan | nan% |
| M8 | 1.0 | 0.02379 | 0.01971 | +17.2% | 0.03979 | 0.03202 | +19.5% | 10.44 (24★) | 10.38 | 0.49% | nan | nan | nan% |
| Veil | 0.25 | 0.04885 | 0.03611 | +26.1% | 0.04911 | 0.03929 | +20.0% | 12.47 (14★) | 11.45 | 8.21% | 0.1294 | 0.1257 | 97.1% |
| Veil | 0.5 | 0.04885 | 0.02492 | +49.0% | 0.04911 | 0.02955 | +39.8% | 12.47 (14★) | 12.42 | 0.39% | 0.1294 | 0.1236 | 95.5% |
| Veil | 0.75 | 0.04885 | 0.02492 | +49.0% | 0.04911 | 0.02912 | +40.7% | 12.47 (14★) | 12.42 | 0.39% | 0.1294 | 0.1236 | 95.5% |
| Veil | 1.0 | 0.04885 | 0.02379 | +51.3% | 0.04911 | 0.02898 | +41.0% | 12.47 (14★) | 12.33 | 1.09% | 0.1294 | 0.1213 | 93.7% |

GATE at strength 0.5: **FAIL** (verdict VALID: no NaN gate metric, nstars 24/14 ≥ 10, fc0 = 0.1294 > 0)

Failing cells at s=0.5: M8 Δbgσ +17.1% (< 40%), M8 Δchromaσ +17.5% (< 50%),
Veil Δchromaσ +39.8% (< 50%). Passing cells: Veil Δbgσ +49.0% (≥ 40%),
ΔFWHM 0.35% / 0.39% (≤ 2%), Veil filament preserved 95.5% (≥ 95%).

**STOP per plan Step 5 / spec §3:** the wavelet fallback (approach B) decision
belongs to the owner at this gate. No Swift was written.

## Why the gate cannot be met with these constants (upper-bound analysis)

The failure is structural, not a tuning shortfall. Setting every blend weight to 1
(blur everything, no guards — the theoretical maximum for this pipeline shape)
gives on the sky-mask metrics:

| dataset | metric | gate | best observed @0.5 | blur-all upper bound (default radii) | bound at extreme radii |
|---|---|---|---|---|---|
| M8 | Δbgσ | ≥ 40% | +17.1% | +21.1% (r=3×2) | +30.4% (r=12×3) |
| M8 | Δchromaσ | ≥ 50% | +17.5% | +21.9% (d=4, r=5×3) | +25.1% (d=4, r=12×3) |
| Veil | Δbgσ | ≥ 40% | +49.0% | +55.9% | +68.1% |
| Veil | Δchromaσ | ≥ 50% | +39.8% | +58.7% | +61.4% |

On M8 the sky-mask MAD sigma (luma) and 8×-block chroma sigma are dominated by
static large-scale background structure (widespread Sagittarius nebulosity /
gradients across the darkest-30%-tiles mask), which local smoothing cannot and
should not remove — both M8 gates sit far above the blur-everything bound for any
constants. Veil Δchromaσ ≥ 50% is above what remains once any luma-edge guard is
applied (guard-free bound +58.7%, observed +39.8% with the weakest defensible
guard). The blend-gain sweep saturates at gain ≥ 2.0 (min(1, gain·0.5) = 1), so no
gain value changes this.

Blend-gain sweep summary (grid {1.5, 2.0, 2.5, 3.0}² at s=0.5, run with the
original spec starting constants): all pairs with gain ≥ 2.0 are identical
(amplitude saturated at 1); best cells still missed every failing gate above
(max Δchromaσ +11.5%, M8 Δbgσ +18.1%, Veil ΔFWHM 5.94% pre-tuning). Chosen
2.0 / 2.0 — the smallest saturating pair.

## BEST-OBSERVED CONSTANTS (NOT graduated to Swift — gate FAILED)

These are the constants of the recorded gate table (set in the script), reached by
iterating the T1-BINDING values from the spec starting points. They fix the two
fixable failures (Veil ΔFWHM 5.94%→0.39% via LUMA_RESIDUAL_K 2.5→1.5 +
LUMA_SIGMA_PROTECT_K 3→6; weight starvation via CHROMA_EDGE_GRAD 0.08→0.25):

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

## Fixture effect-size floors (recorded; moot until an approach passes the gate)

| assertion constant | value | derivation |
|---|---|---|
| s1MinChromaReduction | 0.125 | stage-1-only coarse chroma reduction @0.5: M8 +17.5%, Veil +39.8%; min minus 5 pt margin |
| s2MinSigmaReduction | 0.121 | stage-2-only bg sigma reduction @0.5: M8 +17.1%, Veil +49.0%; min minus 5 pt margin |

(Measured by disabling the other stage via an external driver that monkeypatches
it to identity — the committed script was not modified.)

## Linear-domain check

Observed linear-domain run on the raw (unstretched) M8 master at 0.5:
bg sigma reduction +16.8%, FWHM delta 0.00% (3.54 → 3.54 px, 40 stars) —
constant CHROMA_EDGE_GRAD_LINEAR = 0.025 validated here (spec §2.3 "linear-domain
strength mapping"; stage-2 thresholds are sigma-relative and therefore domain-free).

## Eyeball A/B notes

- Veil s=0.5: chroma mottle and luma grain visibly reduced; arc rim, star
  profiles, and faint outer shell intact. No visible rectangular tile seams at
  1/32-frame boundaries in the inspected crops.
- M8 s=1.0: nebulosity, dark lanes, and Bok globules retained (mild softening,
  not crushed); no seams.
- Veil s=0.25 ΔFWHM 8.21% is a measurement artifact of the marginal 14-star
  sample at half-amplitude (FWHM *decreased* 12.47→11.45), not star bloat; at
  the gate strength the delta is 0.39%.
