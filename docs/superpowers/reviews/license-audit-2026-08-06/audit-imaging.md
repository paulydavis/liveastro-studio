# Copyright / License Derivation Audit — LiveAstro Studio Imaging vs. Siril (GPLv3)

**Date:** 2026-08-06
**Auditor stance:** adversarial — assume derivation, hunt for evidence, attempt to refute independence.
**Target:** `/Users/pauldavis/liveastro-studio/Sources/LiveAstroCore/Imaging/{AutoStretch,BackgroundExtraction,Denoiser,DisplayAdjustments}.swift` + `Sources/LiveAstroCore/Stacking/Debayer.swift` bilinear path (lines 1–77).
**Reference:** `/private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/siril-src` (checkout dated 2026-08-04, single shallow commit `5c7cfbc`), primarily `src/algos/background_extraction.c`, `src/algos/colors.c`, `src/algos/noise.c`, `src/algos/demosaicing_siril.c`, `src/algos/demosaicing.c`, `src/filters/mtf.c`.

Ground rules applied: the MTF formula is published math (PixInsight STF documentation); bilinear debayer is textbook; only implementation fingerprints (non-published constants, decomposition/loop structure, naming echoes, comment echoes, peculiar tricks) count as evidence.

---

## Verdict summary

| Swift file | Verdict |
|---|---|
| AutoStretch.swift | **ALGORITHM-CONVERGENT** (published PI STF math; implementation decomposition materially differs from Siril's) |
| BackgroundExtraction.swift | **ALGORITHM-CONVERGENT** — with one open caveat (shared conceptual ancestor script not in reference set; see §3.4) |
| Denoiser.swift | **INDEPENDENT** (no counterpart algorithm anywhere in the Siril reference; full in-repo prototype provenance) |
| DisplayAdjustments.swift | **INDEPENDENT** (settings struct; no Siril counterpart to derive from) |
| Debayer.swift bilinear path (lines 36–76) | **ALGORITHM-CONVERGENT** (textbook kernel; expression is the opposite formulation of Siril's); **no RCD leakage found** outside the declared RCD section |

No file rises to SUSPICIOUS or DERIVED against the supplied Siril sources. Details and the near-miss line pairs I chased down follow.

---

## 1. AutoStretch.swift — ALGORITHM-CONVERGENT

### 1.1 Matching elements (all traceable to published PixInsight STF material)

- **MTF formula.** `AutoStretch.swift:12` `((m - 1) * x) / (((2 * m - 1) * x) - m)` vs `src/filters/mtf.c:133` `((m - 1.f) * xp) / (((2.f * m - 1.f) * xp) - m)`. Identical parenthesization — but this is the one natural transcription of the published formula MTF(x;m) = ((m−1)x)/((2m−1)x−m) (PixInsight docs), including the x≤0→0 / x≥1→1 piecewise guards (`AutoStretch.swift:10-11` vs `mtf.c:126-129`, where Siril generalizes to lo/hi). Not probative.
- **Defaults −2.8 / 0.25.** `AutoStretch.swift:17-18` (`targetBackground: Double = 0.25, shadowsClipping: Double = -2.8`) vs `src/filters/mtf.h:12-13` (`AS_DEFAULT_SHADOWS_CLIPPING -2.80f`, `AS_DEFAULT_TARGET_BACKGROUND 0.25f`). These are the published PixInsight auto-STF defaults; both projects inherited them from the same public source. Not probative.
- **MAD×1.4826.** `AutoStretch.swift:51` vs `src/core/siril.h:122` (`MAD_NORM 1.4826`). Universal robust-statistics constant; Swift's comment even derives it (`1/Φ⁻¹(0.75)`). Not probative.

### 1.2 Independence fingerprints (differences that refute copying)

- **Different statistical decomposition.** Siril (`mtf.c:298-364`, `find_linked_midtones_balance`) computes **per-channel** median/MAD via its statistics engine, then averages the per-channel results: `c0 += median + shadows_clipping * mad` (mtf.c:330), `c0 /= nb_channels` (mtf.c:333). Swift (`AutoStretch.swift:35-53`) instead builds a single **mean-of-channels stride-sampled luminance sample** and takes one median/MAD of that. Different math (median of mean ≠ mean of medians), different code shape.
- **Different midtone computation.** Siril: `m2 = m/nb_channels − c0; midtones = MTF(m2, target_bg)` (mtf.c:335-337) — no renormalization, faithful to the published PI recipe. Swift: `r = (median − shadow)/(1 − shadow)` **normalized by the stretched range** before `mtf(r, targetBackground)` (`AutoStretch.swift:56-59`). A copier of either Siril or PI would not introduce this deviation.
- **Different degenerate-MAD guard.** Siril: `if (mad == 0.f) mad = 0.001f;` (mtf.c:328). Swift: `madn = madn_raw > 1e-10 ? madn_raw : max(median, 1e-10)` (`AutoStretch.swift:53`) — different threshold, different fallback semantics (documented rationale: preserve channel ratios).
- **Missing Siril machinery.** Swift has no inverted-image branch (Siril's `invertedChannels` path, mtf.c:342-360), no LUT path, no unlinked variant, no highlights parameter. Swift adds features Siril lacks in this code: linear-domain black-point pre-clip (`AutoStretch.swift:22-29`) and a `midtoneStrength` scaling with a byte-identity-preserving clamp rule (`AutoStretch.swift:58-65`).
- **`neutralizeBackground` (AutoStretch.swift:102-123)** is *multiplicative* (scale R/B so channel medians match G). Siril's `background_neutralize` (`src/algos/colors.c:1151-1191`) is *additive* (`offset = stats[chan]->mean − ref` where ref = mean of channel medians over a user-supplied selection rectangle, colors.c:1165-1184). Different algorithm, different reference (G-median vs mean-of-medians), different sampling (whole frame vs selection). No relationship.
- **`neutralizeBackgroundAdditive` (AutoStretch.swift:134-196)** — 48×48 tile grid, low-percentile-of-tile-medians per channel, subtract down to darkest channel. No counterpart anywhere in `colors.c` (Siril's green-cast tool is SCNR, `src/filters/scnr.c`, a pixelwise min/average method — unrelated).
- **Provenance:** created in commit `8c37738` 2026-07-05 ("linked MTF autostretch + CGImage packing"), extended `150b5bb`/`e791cc9`; the repo's own denoise prototype (`Scripts/prototypes/denoise_prototype.py:91-119`) mirrors this exact Swift implementation (including the (1−shadow) normalization and the max(median,1e-10) guard), confirming the Swift is the family's origin.

**Verdict: ALGORITHM-CONVERGENT.** Everything shared is published PI math + published defaults; every implementation choice where an author has freedom diverges from Siril.

---

## 2. DisplayAdjustments.swift — INDEPENDENT

Pure settings struct (Codable, backward-compat decode, `DisplayAdjustments.swift:18-60`). Siril has no corresponding artifact in the reference set (its parameters live in GUI state / `struct autograd_data`). Defaults `bgScale = 3.0`, `bgSmoothest = 0.5` (`DisplayAdjustments.swift:30`) **differ** from Siril's autograd defaults `scale = 5.0`, `smoothness = 1.0` (`src/core/command.c:8689`) — a place where copying would have shown. Nothing to derive; nothing derived.

---

## 3. BackgroundExtraction.swift — ALGORITHM-CONVERGENT (one caveat)

### 3.1 Polynomial path (`tileSamples`/`solveModel`/`fitBackground`/`flatten`, lines 65–230) vs Siril's sample-based path

Siril (`background_extraction.c:291-418`, `computeBackground_Polynom` + `generate_samples` 897-989):
- samples are **25-px boxes placed per line** (with optional gradient-descent repositioning, dedup, tolerance gate), stored in a GSList;
- fit uses **raw pixel coordinates** (`col = sample->position.x`, background_extraction.c:333-334) with **GSL `gsl_multifit_wlinear`** (background_extraction.c:376-377);
- degrees 1–4 (NPARAM up to 15, background_extraction.c:62-65).

Swift:
- fixed **32×32 integer tile grid**, tile **medians** (`BackgroundExtraction.swift:75-101`);
- coordinates normalized to **[-1,1] via coord/dim*2−1** (`BackgroundExtraction.swift:81-82`) — note Siril's own (different) ag_ code normalizes by `(dim−1)` (background_extraction.c:1717-1718), so even the normalization convention differs;
- **iterative (3×) one-sided MAD σ-clip** of tile medians (`BackgroundExtraction.swift:149-160`), then **hand-rolled normal equations + Gaussian elimination with partial pivoting** (`BackgroundExtraction.swift:163-169, 361-382`);
- degrees 1–2 only; per-channel nil-coeff passthrough semantics.

Nearest echo chased: Swift `rejectionSigma: Double = 2.0` (`BackgroundExtraction.swift:143`) vs Siril's GUI "Grid tolerance" default `2` in MAD units (`src/gui-gtk4/uifiles/background_extraction_dialog.ui:12-17`). Both are one-sided-high robust rejections at 2 MAD — but 2σ high-side rejection of bright (star/nebula) samples is the obvious choice for this problem, the mechanisms differ (Siril: one-shot accept/reject at sample generation; Swift: 3-iteration re-clip of tile medians), and the value is a round generic default. Weak, not probative.

The in-repo spec `docs/history/specs/2026-07-11-background-extraction-design.md` explicitly **rejects** the Siril-style approach ("Sampled DBE with placed/auto-placed points + spline/RBF … deferred; polynomial chosen for safety", line 166-168), which is the opposite of what a port would say.

### 3.2 `flattenMultiscale` (lines 238–311) vs Siril's auto-gradient (`ag_*`) code — the closest call in this audit

Siril's `src/algos/background_extraction.c:1470-1898` implements an "Automatic (sample-free) background model" whose **recipe skeleton matches** the Swift:

| Step | Siril | Swift |
|---|---|---|
| Downsample | block-mean, default factor 4 (`ag_downsample` 1806-1819; `.downsample = 4` command.c:8691) | block-average, `D = 4` (`BackgroundExtraction.swift:248, 260-268`) |
| Scale knob | `radius = lround(scale/100 * min(sw,sh))` (1863) | `scaleRadius = max(1, Int((scale/100) * max(sw,sh)))` (252) |
| Smooth | RT Gaussian ≈ **3 box passes** variance-matched (`AG_PASSES 3`, 1481, 1483-1489) | **triple box blur** ≈ Gaussian by CLT (273-275) |
| Reject | two-sided: high 2σ / low 4σ off median of kept residuals, 20 iters + convergence (`AG_HIGH_K 2.0`, `AG_LOW_K 4.0`, `AG_N_ITER 20`, 1739-1786) | one-sided high 3σ MAD, fixed 5 iters, no convergence test (`k = 3.0`, `maxIters = 5`, 246-283) |
| Mask grow | Gaussian-blur grow with protect_threshold/amount cutoff (`ag_structure_mask` 1593-1612) | binary 4-neighbour dilation, `grow = 2` (281, 345-357) |
| Inpaint | harmonic inpaint: fill with known mean, 10× lowpass-restore (`ag_inpaint_lowpass` 1561-1588) | direct replace masked px with blurred bg (282) |
| Smoothness knob | `sr = lround(radius * smoothness)` final Gaussian (1790-1795) | `sr = scaleRadius * 0.5 * smoothest` triple box (287-292) |
| Upsample | **bilinear** (`ag_resize_bilinear` 1822-1846) | **nearest block-replicate** (294-297) |
| Re-add level | **median** of bg (`level = quickmedian_float…; image − bg + level` 1881-1893) | **min** of model (pedestal, 305-307) |
| Defaults | scale 5.0, smoothness 1.0 (command.c:8689) | bgScale 3.0, bgSmoothest 0.5 (DisplayAdjustments.swift:30) |

**Why this is not DERIVED from the supplied Siril C:** every free implementation choice differs — rejection sidedness and k, iteration count/convergence, grow mechanism, inpaint mechanism, min-vs-max dimension for the radius, the 0.5 factor on smoothness, upsample method, pedestal statistic, shipped defaults. The only exact numeric coincidence is downsample=4.

**Provenance chain (strong):** the Swift is a documented port of a Python prototype whose full pseudocode is committed in `docs/history/plans/2026-07-12-dbe-v3-multiscale.md:81-105` (commit `cb2903d`, 2026-07-12) with the exact constants `k=3.0, grow=2, D=4, max_iters=5`, `sigma = scale_pct/100 * max(sh,sw)`, `gaussian(bg, sigma*0.5*smoothest)`, nearest `np.repeat` upsample, and `ped = up.min()`. Swift `flattenMultiscale` (commit `6c7e0d6`, 2026-07-12) matches that prototype line-for-line (with block-average replacing `[::D,::D]` striding and triple-box replacing `scipy.gaussian_filter`, both documented, commit `dade6dc`). The Swift matches its own prototype, not the Siril C, on every point where the two diverge.

### 3.3 Comment/naming echoes checked

- No comment text in the Swift matches Siril comment text (checked: "breakdown point", "sketchy", "harmonic", "numpy edge padding" — the last appears in *Siril's* C at background_extraction.c:1493, itself evidence Siril's ag_ code descends from a numpy prototype, not from anything Swift-side).
- Knob names: Swift "Scale"/"Smoothest" vs Siril "scale"/"smoothness". See caveat below — these come from a shared public source, per LiveAstro's own spec.

### 3.4 CAVEAT — shared conceptual ancestor outside the reference set

`docs/history/specs/2026-07-12-dbe-v3-multiscale-design.md` **openly attributes the algorithm idea**: "Siril's community 'Auto Gradient Removal' script (Cyril Richard) solves exactly this with a multiscale model … The multiscale algorithm's exact recipe … and default parameters are not published beyond the knob *semantics* … Task 1 is a Python prototype that validates the recipe" (and notes the video defaults ≈5% / ≈1 — which equal Siril's C defaults 5.0/1.0, corroborating that Siril's C and LiveAstro's Swift both descend from that same community script). The script itself (GPL, presumably) was **not in the supplied reference set**, so this audit cannot compare the Swift/prototype against it. The in-repo spec's claim is that only knob semantics (ideas) were taken and the recipe was re-derived and empirically validated; the Swift-vs-Siril-C divergences in §3.2 are consistent with that claim. **Recommendation:** obtain Cyril Richard's "Auto Gradient Removal" script and run this same fingerprint comparison against it to fully close the question. Against the sources actually supplied, the verdict stands at ALGORITHM-CONVERGENT.

---

## 4. Denoiser.swift — INDEPENDENT

- **No counterpart algorithm in the reference set.** `src/algos/noise.c` (161 lines) is a background-noise *measurement* worker (delegates to the statistics engine, noise.c:72-102) — it contains no denoising. Siril's actual denoisers (`src/filters/nlbayes`, `da3d`, `epf.c`, `wavelets.c`) are NL-Bayes / DA3D / edge-preserving-filter / wavelet families; none use the Swift's structure (opponent transform Y=(R+2G+B)/4, C1=R−G, C2=B−G; 4× chroma downsample with dilated luma-edge guard; 32×32 tile median/MAD grid with sigma-relative residual and gradient thresholds). Grep for opponent/chroma constructs across `src/filters/*.c` returns nothing.
- **Complete in-repo provenance:** spec `docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md`; prototype `Scripts/prototypes/denoise_prototype.py` (whose primitives are annotated as 1:1 mirrors of the Swift, e.g. prototype lines 123-139 ↔ `Denoiser.swift:233-257`, 226-253 ↔ 117-174, 256-280 ↔ 179-225); a **failed-gate audit trail** (commit `5014d97` "GATE FAILED … STOP per spec §3", then `c85bcd5` passing an amended gate) and a binding constants table in `docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md` matching `Denoiser.K` (`Denoiser.swift:32-55`) including the idiosyncratic half-up rounding convention note. Fabricating this multi-commit prototype-first history to disguise a port of code that *doesn't exist in the reference* is not a coherent hypothesis.
- Internal reuse is from LiveAstro's own files (boxBlur semantics from `BackgroundExtraction.swift:314-334`, tile grid from `tileSamples`, percentile from `neutralizeBackgroundAdditive` — all cross-referenced in comments), not from Siril.

**Verdict: INDEPENDENT.**

---

## 5. Debayer.swift bilinear path (lines 36–76) — ALGORITHM-CONVERGENT; no RCD leakage

- Swift: **mask-normalized 3×3 kernel convolution** — G kernel = cross `[0,1,0,1,4,1,0,1,0]`, R/B kernel = `[1,2,1,2,4,2,1,2,1]`, per-pixel `num/den` renormalization giving exact edges (`Debayer.swift:43-67`), planar output, `Parallel.rows`.
- Siril: **OpenCV-lineage pointer-marching implementation** (`/* OpenCV's Bayer decoding */`, `demosaicing_siril.c:202-289`) — interleaved RGB, integer `(a+b+1)>>1` / `(a+b+c+d+2)>>2` arithmetic, `blue`/`start_with_green` row parity flags, and **borders cleared to black** (`ClearBorders`, 179-200) — the exact opposite of the Swift's renormalized-edge design.
- The two share only the textbook averaging pattern (which pixels average into which). Zero structural, naming, or constant overlap.
- **RCD leakage check (as tasked):** the declared RCD port occupies `Debayer.swift:78` onward. The bilinear function (36-76) predates it, references nothing from it, and contains no RCD constructs (no directional discriminators, ratio corrections, or librtprocess-style buffers). The RCD builder *consumes* `bilinear()` for its border fill (`Debayer.swift:402-412`) — dataflow runs RCD→bilinear, not the reverse. Across the other audited files, the only occurrence of "RCD" is a process-discipline comment in `Denoiser.swift:31`; no rcd.cc-derived code appears outside the declared section.

**Verdict: ALGORITHM-CONVERGENT** (textbook algorithm, independent expression).

---

## 6. Overall assessment

Hunting adversarially, the strongest candidate for derivation was `flattenMultiscale` vs Siril's `ag_*` auto-gradient code — same recipe skeleton and knob semantics. It dissolves on inspection: the two implementations disagree on essentially every discretionary constant and mechanism (§3.2 table), and LiveAstro's committed prototype-first history (2026-07-12) explains both the recipe and every constant the Swift actually uses. LiveAstro's own documentation is unusually candid about its influences (names Siril, PixInsight, the community script, and declares the RCD port), which is itself inconsistent with concealed copying. The one item this audit could not adjudicate with the supplied materials is the GPL "Auto Gradient Removal" community script (§3.4) — recommended follow-up. The `2026-07-17-siril-parity-benchmark` spec was checked and is output-comparison benchmarking only (explicitly excludes redistribution of Siril data; no code transfer).

**No evidence of code derivation from the supplied Siril GPLv3 sources was found in any audited file.**
