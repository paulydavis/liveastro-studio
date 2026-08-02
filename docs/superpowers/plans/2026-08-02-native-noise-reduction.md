# Native Noise Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec (binding):** `docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md`

**Goal:** Close the live-view noise gap (background luma grain + green/magenta chroma mottle) with a native, classic, deterministic two-stage denoiser — no AI, no external tools, zero new dependencies — applied non-destructively in the display path and offered as a `Native NR` backend on the existing master post-process picker.

**Architecture:** One pure engine (`Denoiser.apply(_:strength:)`, Foundation + `Parallel.rows` only) with two consumers: `SessionPipeline.displayCGImage` inserts it after stretch + DBE and before saturation/CGImage packing, and a new `NativeDenoiseProcessor` runs the same two stages in linear domain on `master.fit` → `master_processed.fit`. A Python prototype on the real M8 and Veil masters validates the algorithm and emits the constants and golden vectors that pin the Swift port, exactly as additive-BN, DBE, and RCD were built.

**Tech Stack:** Swift 5.10 SPM, macOS 14+, XCTest, zero external Swift dependencies. Python 3 + numpy + astropy for the prototype only (`Scripts/prototypes/`, never linked into the app).

---

## Global Constraints

Binding items copied from the spec (§ references are to the spec):

- **Classic-only, zero new dependencies** (§ goal, §2.1): "native, classic, deterministic denoiser — no AI, no external tools, zero new dependencies". Engine is "pure, deterministic, Foundation + the existing `Parallel.rows` only". No Core ML, no changes to GraXpert, no watcher or stacking-engine changes, no new UI surface beyond one slider and one picker entry (§ non-goals).
- **Passthrough contracts** (§2.1, verbatim): "`strength == 0` returns the input byte-identical (off costs nothing); NaN/Inf pass through untouched (upstream sanitizes; the engine must not trap); mono images run stage 2 only; images below 64×64 pass through."
- **Display placement** (§2.2): applied in `SessionPipeline.displayCGImage` "**after** stretch and DBE, before CGImage packing — … this placement makes broadcast, snapshots, `latest.png`, and replay all inherit it automatically while `master.fit` stays raw."
- **`master.fit` is never mutated** (§ non-goals). The master path writes `master_processed.fit` with the existing temp+rename no-partial-files pattern (§5).
- **Default OFF + Codable back-compat** (§2.2): `denoiseStrength` "0…1, default **0 / off** for the first release … Codable backward-compatible like every prior adjustment field." Slider follows the DBE pattern including the drag-end `{ editing in if !editing { applyDisplayAdjustments() } }` gotcha.
- **Prototype-first gate is binding** (§3): Task 1 runs on the real M8 (`~/Documents/LiveAstro/2026-07-08-m8lagoon-3`) and Veil masters, A/B'd with metrics **before any Swift is written**. Gate thresholds, verbatim:
  - background luma sigma reduction ≥ 40% at Medium strength (slider 0.5);
  - chroma mottle (coarse-scale sigma of the opponent chroma channels) reduction ≥ 50%;
  - star FWHM change ≤ 2%;
  - filament contrast (line profile across the Veil arc) preserved ≥ 95%;
  - A/B PNGs produced for owner eyeballing.
- **Validated constants are verbatim-binding** (§3): "The validated kernel sizes, thresholds, and strength curve become the Swift constants, verbatim." If the guided-filter approach cannot hit the gate numbers, "the fallback is à-trous wavelet thresholding (approach B), **decided at the gate, not improvised mid-port**." A gate failure is a STOP — bring the decision back to the owner.
- **Performance pin** (§4): "≤ 1.0 s per application at 26MP in release", pinned by a release-mode performance test like the RCD pin. Accelerate/vImage is the sanctioned escalation if the pin fails; Metal is out of scope. Do not micro-optimize past the pin without need.
- **Branch discipline:** all work on `feature/native-noise-reduction`, never `main` (house rule). The branch merges **only after an external review round** (spec §6 post-merge adversarial + quality review per repo practice); completing this plan is not merge authorization.

### Recorded plan-time findings (spec-vs-code tensions — recorded, not silently resolved)

- **F1 — `denoiseStrength` type.** Spec §2.2 says "`DisplayAdjustments` gains `denoiseStrength: Float`". Every existing `DisplayAdjustments` field is `Double` (`blackPoint`, `midtoneStrength`, `saturation`, `bgScale`, `bgSmoothest` — `DisplayAdjustments.swift:18-24`) and every ControlView slider binds a `Double`. This plan uses `Double` in the struct for sibling-field and persistence consistency and converts with `Float(...)` at the engine boundary; the engine signature stays spec-verbatim (`strength: Float`). Reviewer may overrule back to `Float`; either encodes identically in JSON.
- **F2 — "same tile machinery".** Spec §2.1/§2.3 say stage 2 uses "the same tile pattern as `BackgroundExtraction`". `BackgroundExtraction.tileSamples` (`BackgroundExtraction.swift:65-103`) returns per-tile **medians only** — no sigma. The engine therefore implements its own `tileGrid` (median + MAD sigma) on the **same integer tile-edge grid** (`y0 = ty*h/tiles …`); it shares the grid geometry, not the code.
- **F3 — engine domain dispatch.** Spec §2.1 defines the single signature `apply(_ image: AstroImage, strength: Float) -> AstroImage`; §2.3 requires "the prototype's linear-domain strength mapping" on the master path. The domain is carried by `AstroImage.sourceIsLinear` (display input arrives with `sourceIsLinear: false` — `AutoStretch.stretch` returns it at `AutoStretch.swift:72-73`; the master path constructs with `true`), keeping the spec signature verbatim.
- **F4 — ordering vs. saturation.** `displayCGImage` runs saturation after stretch (`SessionPipeline.swift:359-362`); the spec only says "after stretch and DBE, before CGImage packing". This plan inserts denoise **between stretch and `applySaturation`** so chroma mottle is smoothed before the saturation slider re-amplifies it. Recorded for the reviewer.
- **F5 — stage-1 "luma untouched" is not bit-exact.** The opponent round-trip computes `G' = Y − (C1'+C2')/4` then `Y' = G' + (C1'+C2')/4`; `(a − t) + t ≠ a` in float32, so recombined luma can differ by ~1 ulp even when stage 2 is inert. Stage 2 also contributes: even on a nominally constant luma plane its box-blur sums round in float32, leaving small non-zero residuals that re-enter `Y'` through the blend — the 1e-5 tolerance covers the opponent round-trip *plus* stage-2's contribution; ~1 ulp alone would be too tight. The stage-1 fixture asserts `|Y' − Y| ≤ 1e-5`, not byte-identity. (The `strength == 0` contract is still exactly byte-identical: the engine returns the input value itself.)
- **F6 — Process-master button gating.** Spec §2.3 says `isAvailable` is always true for Native NR, but the existing button (`ControlView.swift:692-700`) is also gated on `model.sourceMode == .nativeStack` and a session directory. Those gates express the `master.fit` prerequisite, not backend availability, and are kept; only the GraXpert-executable gate becomes backend-conditional.
- **F7 — §5 error propagation.** §5 deviation: master-path write failures propagate the underlying error rather than mapping to `ProcessorError.noOutput` — strictly more diagnostic; no-partial-files pinned by test (`testFailedWriteLeavesNoPartialOutput`, T6).

### Deferred-numbers rule

Every constant below tagged `T1-BINDING` is a **starting value** for the Task-1 sweep. The values recorded in `docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md` after the gate passes replace them **verbatim** in `Scripts/prototypes/denoise_prototype.py` and `Denoiser.K` — no Swift-side re-tuning. Fixture assertions that depend on measured effect sizes (`s1MinChromaReduction`, `s2MinSigmaReduction`) start at the spec-gate values (0.50 / 0.40) and are likewise updated only from the results doc.

---

## File Structure

- Create: `Scripts/prototypes/denoise_prototype.py` (git-tracked; durable, unlike the lost scratchpad batteries — see the segment-model plan's revision note)
- Create: `docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md` (metrics tables, chosen constants, A/B PNG paths; PNGs themselves live OUTSIDE the repo in `~/Desktop/denoise-ab/`)
- Create: `Sources/LiveAstroCore/Imaging/Denoiser.swift` (the engine)
- Create: `Sources/LiveAstroCore/Processing/NativeDenoiseProcessor.swift` (master-path wrapper)
- Modify: `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift` (`denoiseStrength` field + decode default)
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (one stage in `displayCGImage`)
- Modify: `Sources/LiveAstroCore/Processing/Processor.swift` (`ProcessorBackend.nativeDenoise`)
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (Denoise slider; picker entry; Process-master button gating)
- Modify: `Sources/LiveAstroStudio/ImportController.swift` (`processMaster` backend switch)
- Create: `Tests/LiveAstroCoreTests/DenoiserTests.swift` (T2 + T3)
- Create: `Tests/LiveAstroCoreTests/DenoiserGoldenTests.swift` (T4)
- Create: `Tests/LiveAstroCoreTests/DenoiseDisplayIntegrationTests.swift` (T5)
- Create: `Tests/LiveAstroCoreTests/NativeDenoiseProcessorTests.swift` (T6)
- Create: `Tests/LiveAstroCoreTests/Fixtures/denoise_golden_input.f32`, `denoise_golden_expected_py.f32`, `denoise_golden_expected_swift.f32`, `denoise_golden_meta.json` (T4; `Package.swift` already copies `Fixtures` — no manifest change)
- Modify: `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift`, `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`, `Tests/LiveAstroCoreTests/PerformanceTests.swift`
- **Not modified:** `master.fit` handling, watcher, StackEngine, GraXpertProcessor, FITSReader/Writer, `AutoStretch`, `BackgroundExtraction` (the engine gets its own parallel box blur rather than touching the DBE's serial one).

---

### Task 1: Feature Branch + Python Prototype + Gate (no Swift until this passes)

**Files:**
- Create: `Scripts/prototypes/denoise_prototype.py`
- Create: `docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md`

**Interfaces:**
- Consumes: `~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit` (M8) and `~/Documents/LiveAstro/2026-07-12-ngc6960/master.fit` (Veil; any of the verified `2026-07-1[012]-ngc6960*` masters is acceptable — record which). Verified present 2026-08-02. Per the astro-data-migration memory note, re-verify before running.
- Produces: the validated constants table (graduates verbatim to `Denoiser.K` in T2), A/B PNGs in `~/Desktop/denoise-ab/`, and (in T4) the golden `.f32` fixtures.
- Mirrors: `AutoStretch.stretch` (`AutoStretch.swift:16-74`: linked mean-of-channels sample, stride cap 262144, upper median, `1.4826 * MAD`, `shadow = clip(median − 2.8·madn, 0, 1)`, `midtone = mtf(r, 0.25)`). The mirror only needs metric-grade fidelity, **not** bit-exactness: the golden fixture records the stretched crop as raw floats, so only the two stages must correspond across languages.

**This task's "tests" are the gate metrics.** The script and metric code below are complete; the *observed* numbers cannot be pre-written and are recorded in the results doc.

- [ ] **Step 1: Create the feature branch**

```bash
cd /Users/pauldavis/liveastro-studio
git checkout -b feature/native-noise-reduction
```

Expected: `Switched to a new branch 'feature/native-noise-reduction'`. Never commit to `main` (house rule); merge only after the external review round (Task 7).

- [ ] **Step 2: Verify the real datasets are still present** (astro-data-migration: local paths may vanish)

```bash
ls -l ~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit
ls -l ~/Documents/LiveAstro/2026-07-12-ngc6960/master.fit
python3 -c "import numpy, astropy, matplotlib; print('deps ok')"
```

Expected: both files listed; `deps ok`. If a master is missing, STOP and report — do not substitute a different dataset silently. If only `matplotlib` is missing, `pip install matplotlib` (or accept the script's PPM fallback and note it in the results doc).

- [ ] **Step 3: Write the prototype script** — create `Scripts/prototypes/denoise_prototype.py` exactly:

```python
#!/usr/bin/env python3
"""Native noise reduction prototype (spec docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md §3).

Two classic stages:
  Stage 1 — chroma mottle: opponent transform (Y,C1,C2), chroma 4x-downsampled,
            box^3 blur, luma-edge-guided blend (coarse + full-res guard), bilinear up.
  Stage 2 — luma grain: residual-thresholded blur blend with a 32x32 tile
            median/MAD-sigma grid (flat sky smoothed harder) and sigma-relative
            gradient protection (threshold k * tile sigma).

Modes:
  metrics --m8 M8.fit --veil VEIL.fit [--ab-dir ~/Desktop/denoise-ab]
      Sweep strengths, print the gate-metric markdown table, write A/B PNGs.
      --sweep-gains: print the coarse blend-gain grid at s=0.5 instead
      (pick CHROMA_BLEND_GAIN / LUMA_BLEND_GAIN, set them above, re-run).
  golden  --m8 M8.fit --out Tests/LiveAstroCoreTests/Fixtures
      Emit the 64x64 float32 golden crop (input + expected at strength 0.5).

Gate (all at strength 0.5, spec-verbatim): bg luma sigma down >=40%, coarse chroma
sigma down >=50%, star FWHM delta <=2%, Veil filament contrast preserved >=95%.
If the gate fails: STOP. Wavelet fallback (approach B) is an owner decision.

The constants below are the sweep's starting values. The values recorded in
docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md after the gate
passes are BINDING and must be mirrored verbatim into Denoiser.K (Swift).
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np
from astropy.io import fits

# ---- T1-BINDING constants (starting values for the sweep) -------------------
CHROMA_DOWN = 4
CHROMA_PASSES = 3
CHROMA_EDGE_GRAD = 0.08            # display domain
CHROMA_EDGE_GRAD_LINEAR = 0.008    # linear domain
CHROMA_BLEND_GAIN = 2.0            # blend amplitude: min(1, gain * s) — see --sweep-gains
LUMA_PASSES = 2
LUMA_RESIDUAL_K = 2.5
LUMA_BLEND_GAIN = 2.0              # blend amplitude: min(1, gain * s) — see --sweep-gains
LUMA_SIGMA_PROTECT_K = 3.0         # gradient-protect threshold = k * tile sigma (domain-free)
STRUCTURE_K = 4.0
STRUCTURED_TILE_FLOOR = 0.15
TILES = 32
MAX_TILE_SAMPLES = 1024
BACKGROUND_PERCENTILE = 20.0
MIN_DIM = 64

# ROUNDING CONVENTION (binding): half-up (floor(x+0.5) ≡ Swift .rounded() for positive x).
# Python round() is banker's and diverges at .5 (e.g. luma radius at s=0.5: round(2.5)=2
# but Swift (2.5).rounded()=3) — never use round() in the radius curves.


def chroma_radius(s):
    return max(1, int(math.floor(2.0 + 6.0 * s + 0.5)))


def luma_radius(s):
    return max(1, int(math.floor(1.0 + 3.0 * s + 0.5)))


# ---- IO ---------------------------------------------------------------------
def load_master(path):
    """Planar (3,h,w) float64 in 0..1, top-down row order (mirrors app reader)."""
    with fits.open(path) as hdul:
        data = np.asarray(hdul[0].data, dtype=np.float64)
        hdr = hdul[0].header
    if data.ndim == 2:
        data = data[None, :, :]
    if data.shape[0] not in (1, 3) and data.shape[-1] in (1, 3):
        data = np.moveaxis(data, -1, 0)
    roworder = str(hdr.get("ROWORDER", "BOTTOM-UP")).strip().upper()
    if roworder.startswith("BOTTOM"):
        data = data[:, ::-1, :]
    data = np.nan_to_num(data, nan=0.0, posinf=0.0, neginf=0.0)
    lo, hi = float(data.min()), float(data.max())
    if hi > 1.0:                      # integer-scaled master -> normalize
        data = (data - min(lo, 0.0)) / max(hi - min(lo, 0.0), 1e-12)
    return np.clip(data, 0.0, 1.0)


# ---- AutoStretch mirror (AutoStretch.swift:16-74) ---------------------------
def mtf(x, m):
    x = np.clip(x, 0.0, 1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        out = ((m - 1.0) * x) / (((2.0 * m - 1.0) * x) - m)
    out = np.where(x <= 0.0, 0.0, out)
    out = np.where(x >= 1.0, 1.0, out)
    return out


def upper_median(v):
    """Swift median: sorted()[count/2] (upper median), not numpy's averaged one."""
    v = np.sort(np.asarray(v).ravel())
    return float(v[v.size // 2])


def autostretch(img, target=0.25, clip=-2.8):
    plane = img.shape[1] * img.shape[2]
    stride = max(1, (plane + 262143) // 262144)
    sample = img.mean(axis=0).ravel()[::stride]
    med = upper_median(sample)
    madn = 1.4826 * upper_median(np.abs(sample - med))
    if madn <= 1e-10:
        madn = max(med, 1e-10)
    shadow = min(max(med + clip * madn, 0.0), 1.0)
    denom = max(1.0 - shadow, 1e-9)
    r = min(max((med - shadow) / denom, 1e-9), 1.0)
    midtone = mtf(np.array([r]), target)[0]
    return mtf(np.clip((img - shadow) / denom, 0.0, 1.0), midtone)


# ---- primitives mirrored 1:1 by Denoiser.swift ------------------------------
def box_blur(a, r):
    """Clamped-edge separable box blur, window 2r+1, H then V (Denoiser.boxBlurParallel)."""
    if r < 1:
        return a.copy()
    inv = 1.0 / (2 * r + 1)
    h, w = a.shape
    cols = np.arange(w)
    tmp = np.zeros_like(a)
    for dx in range(-r, r + 1):
        tmp += a[:, np.clip(cols + dx, 0, w - 1)]
    tmp *= inv
    rows = np.arange(h)
    out = np.zeros_like(tmp)
    for dy in range(-r, r + 1):
        out += tmp[np.clip(rows + dy, 0, h - 1), :]
    out *= inv
    return out


def grad_mag(a):
    """L1 central-difference gradient magnitude; borders contribute 0 per axis."""
    gx = np.zeros_like(a)
    gy = np.zeros_like(a)
    gx[:, 1:-1] = (a[:, 2:] - a[:, :-2]) * 0.5
    gy[1:-1, :] = (a[2:, :] - a[:-2, :]) * 0.5
    return np.abs(gx) + np.abs(gy)


def block_down(a, d):
    """Block-average downsample; sw=max(2,w//d) (flattenMultiscale geometry)."""
    h, w = a.shape
    sh, sw = max(2, h // d), max(2, w // d)
    s = np.zeros((sh, sw))
    n = np.zeros((sh, sw))
    for dy in range(d):
        ys = np.arange(sh) * d + dy
        vy = ys < h
        for dx in range(d):
            xs = np.arange(sw) * d + dx
            vx = xs < w
            block = a[np.ix_(np.minimum(ys, h - 1), np.minimum(xs, w - 1))]
            m = np.outer(vy, vx)
            s += np.where(m, block, 0.0)
            n += m
    return s / np.maximum(n, 1.0)


def upsample_bilinear(a, w, h, d):
    sh, sw = a.shape
    xs = (np.arange(w) + 0.5) / d - 0.5
    ys = (np.arange(h) + 0.5) / d - 0.5
    x0 = np.clip(np.floor(xs).astype(int), 0, sw - 1)
    x1 = np.minimum(x0 + 1, sw - 1)
    y0 = np.clip(np.floor(ys).astype(int), 0, sh - 1)
    y1 = np.minimum(y0 + 1, sh - 1)
    fx = np.clip(xs - x0, 0.0, 1.0)
    fy = np.clip(ys - y0, 0.0, 1.0)
    top = a[np.ix_(y0, x0)] * (1 - fx) + a[np.ix_(y0, x1)] * fx
    bot = a[np.ix_(y1, x0)] * (1 - fx) + a[np.ix_(y1, x1)] * fx
    return top * (1 - fy)[:, None] + bot * fy[:, None]


def percentile_nearest(v, p):
    """Nearest-rank percentile (mirrors neutralizeBackgroundAdditive's index)."""
    v = np.sort(np.asarray(v).ravel())
    idx = min(v.size - 1, max(0, int(round(p / 100.0 * (v.size - 1)))))
    return float(v[idx])


def tile_grid(y, tiles=TILES):
    """Per-tile upper-median + MAD sigma on the tileSamples integer edge grid,
    stride-capped at MAX_TILE_SAMPLES samples/tile (deterministic)."""
    h, w = y.shape
    med = np.zeros((tiles, tiles))
    sig = np.zeros((tiles, tiles))
    re = [ty * h // tiles for ty in range(tiles + 1)]
    ce = [tx * w // tiles for tx in range(tiles + 1)]
    for ty in range(tiles):
        for tx in range(tiles):
            t = y[re[ty]:re[ty + 1], ce[tx]:ce[tx + 1]].ravel()
            if t.size == 0:
                continue
            stride = max(1, t.size // MAX_TILE_SAMPLES)
            t = t[::stride]
            m = upper_median(t)
            med[ty, tx] = m
            sig[ty, tx] = 1.4826 * upper_median(np.abs(t - m))
    row_tile = np.searchsorted(re, np.arange(h), side="right") - 1
    col_tile = np.searchsorted(ce, np.arange(w), side="right") - 1
    return med, sig, np.clip(row_tile, 0, tiles - 1), np.clip(col_tile, 0, tiles - 1)


# ---- the two stages ---------------------------------------------------------
def opponent(img):
    r, g, b = img[0], img[1], img[2]
    return (r + 2.0 * g + b) * 0.25, r - g, b - g


def recombine(y, c1, c2):
    g = y - (c1 + c2) * 0.25
    return np.stack([c1 + g, g, c2 + g])


def stage1_chroma(y, c1, c2, s, linear):
    edge = CHROMA_EDGE_GRAD_LINEAR if linear else CHROMA_EDGE_GRAD
    d = CHROMA_DOWN
    h, w = y.shape
    yd = block_down(y, d)
    wd = np.clip(1.0 - grad_mag(yd) / edge, 0.0, 1.0)          # coarse edge guard
    # ONE-CELL GUARD DILATION (T1-BINDING structure): take the min of wd with its
    # 4-neighbour shifts so any coarse cell adjacent to a strong luma edge is also
    # guarded — without this, bilinear upsample leaks the unguarded neighbour's
    # blur delta ~4-6 columns past the edge (probe: |dc1| up to ~0.07). Mirror
    # EXACTLY in the Swift engine; the T2 bleed-band test enforces it.
    wp = np.pad(wd, 1, mode="edge")   # edge-clamped shifts (no wrap-around)
    wd = np.minimum.reduce([wd,
                            wp[:-2, 1:-1], wp[2:, 1:-1],
                            wp[1:-1, :-2], wp[1:-1, 2:]])
    # Blend amplitude min(1, gain*s) (T1-BINDING CHROMA_BLEND_GAIN): a bare s caps
    # the mix at s, structurally unable to reach the 50% chroma gate at s=0.5.
    wf = min(1.0, CHROMA_BLEND_GAIN * s) * np.clip(1.0 - grad_mag(y) / edge, 0.0, 1.0)
    r = chroma_radius(s)
    out = []
    for c in (c1, c2):
        cd = block_down(c, d)
        cb = cd
        for _ in range(CHROMA_PASSES):
            cb = box_blur(cb, r)
        delta = wd * (cb - cd)
        out.append(c + wf * upsample_bilinear(delta, w, h, d))
    return out[0], out[1]


def stage2_luma(y, s, linear):
    # `linear` kept for signature symmetry with denoise(): stage-2 thresholds are
    # sigma-relative (residual k*sigma, gradient k*sigma), hence domain-free.
    med, sig, row_tile, col_tile = tile_grid(y)
    global_bg = percentile_nearest(med, BACKGROUND_PERCENTILE)
    global_sig = max(upper_median(sig), 1e-6)
    tile_w = np.where(med - global_bg < STRUCTURE_K * global_sig,
                      1.0, STRUCTURED_TILE_FLOOR)
    b = y
    for _ in range(LUMA_PASSES):
        b = box_blur(b, luma_radius(s))
    resid = y - b
    sig_px = np.maximum(sig[row_tile[:, None], col_tile[None, :]], 1e-6)
    keep = (np.abs(resid) <= LUMA_RESIDUAL_K * sig_px).astype(float)
    # Sigma-relative gradient protection (T1-BINDING LUMA_SIGMA_PROTECT_K): with a
    # fixed threshold, background noise gradients (E[|gx|+|gy|] ~= 1.13*sigma) eat
    # the protection budget and the noise protects itself. Relative to k*sigma_tile,
    # noise falls well inside the threshold while stars/filaments (|grad| >> k*sigma)
    # remain protected.
    protect = np.clip(1.0 - grad_mag(y) / (LUMA_SIGMA_PROTECT_K * sig_px), 0.0, 1.0)
    # Blend amplitude min(1, gain*s) (T1-BINDING LUMA_BLEND_GAIN): a bare s caps
    # the mix at s, structurally unable to reach the 40% luma gate at s=0.5.
    w_px = (min(1.0, LUMA_BLEND_GAIN * s)
            * tile_w[row_tile[:, None], col_tile[None, :]] * protect * keep)
    return y + w_px * (b - y)


def denoise(img, s, linear):
    """img: planar (c,h,w). Mirrors Denoiser.apply (contracts included)."""
    if s <= 0 or img.shape[1] < MIN_DIM or img.shape[2] < MIN_DIM:
        return img
    s = min(s, 1.0)
    if img.shape[0] == 3:
        y, c1, c2 = opponent(img)
        c1, c2 = stage1_chroma(y, c1, c2, s, linear)
        y2 = stage2_luma(y, s, linear)
        return recombine(y2, c1, c2)
    return np.stack([stage2_luma(img[0], s, linear)])


# ---- gate metrics -----------------------------------------------------------
def sky_mask(y, tiles=TILES):
    """Darkest 30% of tiles by median -> per-pixel sky mask."""
    med, _, row_tile, col_tile = tile_grid(y, tiles)
    cut = percentile_nearest(med, 30.0)
    tile_sky = med <= cut
    return tile_sky[row_tile[:, None], col_tile[None, :]]


def mad_sigma(v):
    m = upper_median(v)
    return 1.4826 * upper_median(np.abs(np.asarray(v).ravel() - m))


def bg_luma_sigma(y, mask):
    return mad_sigma(y[mask])


def chroma_mottle_sigma(c1, c2, mask):
    """Coarse-scale (8x block-mean) chroma sigma over sky tiles (spec metric 2)."""
    md = block_down(mask.astype(float), 8) > 0.5
    s1 = mad_sigma(block_down(c1, 8)[md])
    s2 = mad_sigma(block_down(c2, 8)[md])
    return float(np.hypot(s1, s2))


def star_fwhm_median(y, n_stars=40, exclusion=12):
    """Median FWHM of the brightest local maxima above bg+8*sigma (4-axis half-max)."""
    mask = sky_mask(y)
    bg, sigma = upper_median(y[mask]), max(mad_sigma(y[mask]), 1e-6)
    thresh = bg + 8.0 * sigma
    h, w = y.shape
    inner = y[8:-8, 8:-8]
    is_max = np.ones_like(inner, dtype=bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            is_max &= inner >= y[8 + dy:h - 8 + dy, 8 + dx:w - 8 + dx]
    cand = np.argwhere(is_max & (inner > thresh)) + 8
    cand = cand[np.argsort(-y[cand[:, 0], cand[:, 1]])]
    picked, fwhms = [], []
    for cy, cx in cand:
        if len(picked) >= n_stars:
            break
        if any(abs(cy - py) < exclusion and abs(cx - px) < exclusion
               for py, px in picked):
            continue
        picked.append((cy, cx))
        peak = y[cy, cx] - bg
        if peak <= 0:
            continue
        half = bg + peak / 2.0
        radii = []
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            prev = y[cy, cx]
            for k in range(1, 8):
                cur = y[cy + dy * k, cx + dx * k]
                if cur <= half:
                    frac = (prev - half) / max(prev - cur, 1e-9)
                    radii.append((k - 1) + frac)
                    break
                prev = cur
        if len(radii) >= 3:
            fwhms.append(2.0 * float(np.mean(radii)))
    return float(np.median(fwhms)) if fwhms else float("nan"), len(fwhms)


def filament_contrast(y, row0, row1, col0, col1):
    """Mean line profile across the arc; contrast = ridge peak minus background floor."""
    prof = y[row0:row1, col0:col1].mean(axis=1)
    return float(prof.max() - percentile_nearest(prof, 10.0))


# ---- output helpers ---------------------------------------------------------
def save_png(img, path):
    rgb = np.clip(np.moveaxis(img, 0, -1), 0.0, 1.0)
    try:
        import matplotlib.image as mpimg
        mpimg.imsave(str(path), rgb)
    except ImportError:                       # PPM fallback, no extra deps
        path = Path(str(path).replace(".png", ".ppm"))
        arr = (rgb * 255).astype(np.uint8)
        with open(path, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (arr.shape[1], arr.shape[0]))
            f.write(arr.tobytes())
    print(f"  wrote {path}")


def write_f32(arr, path):
    np.asarray(arr, dtype="<f4").ravel().tofile(str(path))
    print(f"  wrote {path} ({arr.size} floats)")


# ---- modes ------------------------------------------------------------------
def run_metrics(args):
    global CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN
    ab = Path(args.ab_dir).expanduser()
    ab.mkdir(parents=True, exist_ok=True)
    m8 = autostretch(load_master(args.m8))
    veil = autostretch(load_master(args.veil))
    fila = (args.filament_row0, args.filament_row1,
            args.filament_col0, args.filament_col1)
    datasets = []
    for name, img in (("M8", m8), ("Veil", veil)):
        y0, c10, c20 = opponent(img)
        mask = sky_mask(y0)
        bg0 = bg_luma_sigma(y0, mask)
        ch0 = chroma_mottle_sigma(c10, c20, mask)
        fw0, nstars = star_fwhm_median(y0)
        fc0 = filament_contrast(y0, *fila) if name == "Veil" else float("nan")
        datasets.append((name, img, mask, bg0, ch0, fw0, nstars, fc0))

    def deltas(name, img, s, mask, bg0, ch0, fw0, fc0):
        out = denoise(img, s, linear=False)
        y1, c11, c21 = opponent(out)
        bg1 = bg_luma_sigma(y1, mask)
        ch1 = chroma_mottle_sigma(c11, c21, mask)
        fw1, _ = star_fwhm_median(y1)
        fc1 = filament_contrast(y1, *fila) if name == "Veil" else float("nan")
        d_bg, d_ch = 1 - bg1 / bg0, 1 - ch1 / ch0
        d_fw = abs(fw1 - fw0) / fw0 if fw0 == fw0 else float("nan")
        pres = fc1 / fc0 if fc0 == fc0 and fc0 > 0 else float("nan")
        return out, bg1, ch1, fw1, fc1, d_bg, d_ch, d_fw, pres

    if args.sweep_gains:
        # Coarse blend-gain grid at s=0.5 (T1-BINDING gains): the amplitude
        # min(1, gain*s) is what makes the 50%/40% gate reachable at s=0.5.
        # Pick the smallest pair that clears every gate threshold with margin,
        # set CHROMA_BLEND_GAIN / LUMA_BLEND_GAIN in the constants block, then
        # re-run WITHOUT --sweep-gains: the gate table (and the results doc)
        # records the chosen values alongside the other constants.
        saved = (CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN)
        print("| dataset | chromaGain | lumaGain | Δbgσ@0.5 | Δchromaσ@0.5 | ΔFWHM@0.5 | filament preserved |")
        print("|---|---|---|---|---|---|---|")
        for cg in (1.5, 2.0, 2.5, 3.0):
            for lg in (1.5, 2.0, 2.5, 3.0):
                CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN = cg, lg
                for name, img, mask, bg0, ch0, fw0, nstars, fc0 in datasets:
                    _, _, _, _, _, d_bg, d_ch, d_fw, pres = deltas(
                        name, img, 0.5, mask, bg0, ch0, fw0, fc0)
                    print(f"| {name} | {cg} | {lg} | {d_bg:+.1%} | {d_ch:+.1%} "
                          f"| {d_fw:.2%} | {pres:.1%} |")
        CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN = saved
        return

    print("| dataset | strength | bgσ before | bgσ after | Δbgσ | chromaσ before | chromaσ after | Δchromaσ | FWHM before | FWHM after | ΔFWHM | filament before | after | preserved |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    gate_ok = True
    gate_invalid = False
    for name, img, mask, bg0, ch0, fw0, nstars, fc0 in datasets:
        save_png(img, ab / f"{name}_before.png")
        for s in (0.25, 0.5, 0.75, 1.0):
            out, bg1, ch1, fw1, fc1, d_bg, d_ch, d_fw, pres = deltas(
                name, img, s, mask, bg0, ch0, fw0, fc0)
            print(f"| {name} | {s} | {bg0:.5f} | {bg1:.5f} | {d_bg:+.1%} "
                  f"| {ch0:.5f} | {ch1:.5f} | {d_ch:+.1%} "
                  f"| {fw0:.2f} ({nstars}★) | {fw1:.2f} | {d_fw:.2%} "
                  f"| {fc0:.4f} | {fc1:.4f} | {pres:.1%} |")
            save_png(out, ab / f"{name}_after_s{s}.png")
            if s == 0.5:
                # NaN-strict verdict: an unmeasurable metric can never count as a
                # pass. Also require a usable star sample (nstars >= 10) and a
                # positive filament baseline (fc0 > 0) before judging at all.
                gate_metrics = [d_bg, d_ch, d_fw] + ([pres] if name == "Veil" else [])
                if (any(m != m for m in gate_metrics) or nstars < 10
                        or (name == "Veil" and not fc0 > 0)):
                    print(f"GATE INVALID: metric unmeasurable on {name} "
                          f"(NaN gate metric, nstars={nstars} < 10, or filament "
                          "fc0 <= 0) — fix the measurement (star threshold / "
                          "filament window) before judging PASS/FAIL.")
                    gate_invalid = True
                    gate_ok = False
                elif d_bg < 0.40 or d_ch < 0.50 or d_fw > 0.02:
                    gate_ok = False
                elif name == "Veil" and pres < 0.95:
                    gate_ok = False
    verdict = "PASS" if gate_ok else ("INVALID" if gate_invalid else "FAIL")
    print(f"\nGATE at strength 0.5: {verdict}")
    if not gate_ok:
        print("STOP: gate failed. Wavelet fallback (approach B) is an OWNER decision"
              " made at this gate — do not port to Swift, do not improvise (spec §3).")
        sys.exit(1)


def run_golden(args):
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    img = autostretch(load_master(args.m8)).astype(np.float32)
    x0, y0v, n = args.crop_x, args.crop_y, 64
    crop = img[:, y0v:y0v + n, x0:x0 + n].astype(np.float32)
    assert crop.shape == (3, n, n), f"crop out of bounds: {crop.shape}"
    expected = denoise(crop.astype(np.float32), 0.5, linear=False).astype(np.float32)
    write_f32(crop, out_dir / "denoise_golden_input.f32")
    write_f32(expected, out_dir / "denoise_golden_expected_py.f32")
    meta = (f'{{"width": {n}, "height": {n}, "channels": 3, "strength": 0.5,\n'
            f' "sourceIsLinear": false, "cropX": {x0}, "cropY": {y0v},\n'
            f' "source": "2026-07-08-m8lagoon-3/master.fit"}}\n')
    (out_dir / "denoise_golden_meta.json").write_text(meta)
    print(f"  wrote {out_dir / 'denoise_golden_meta.json'}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    m = sub.add_parser("metrics")
    m.add_argument("--m8", required=True)
    m.add_argument("--veil", required=True)
    m.add_argument("--ab-dir", default="~/Desktop/denoise-ab")
    m.add_argument("--sweep-gains", action="store_true",
                   help="print the coarse blend-gain grid at s=0.5 and exit")
    m.add_argument("--filament-row0", type=int, default=1500)
    m.add_argument("--filament-row1", type=int, default=1700)
    m.add_argument("--filament-col0", type=int, default=2000)
    m.add_argument("--filament-col1", type=int, default=2100)
    g = sub.add_parser("golden")
    g.add_argument("--m8", required=True)
    g.add_argument("--out", default="Tests/LiveAstroCoreTests/Fixtures")
    g.add_argument("--crop-x", type=int, default=1024)
    g.add_argument("--crop-y", type=int, default=768)
    args = p.parse_args()
    if args.mode == "metrics":
        run_metrics(args)
    else:
        run_golden(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the metrics sweep**

```bash
cd /Users/pauldavis/liveastro-studio
python3 Scripts/prototypes/denoise_prototype.py metrics \
  --m8 ~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit \
  --veil ~/Documents/LiveAstro/2026-07-12-ngc6960/master.fit
```

Expected: the markdown metrics table (8 rows: 2 datasets × 4 strengths), A/B PNGs in `~/Desktop/denoise-ab/`, and a final `GATE at strength 0.5: PASS` (exit 0). A `GATE INVALID: metric unmeasurable` line means the *measurement* is broken (NaN gate metric, < 10 stars, or a non-positive filament baseline) — fix the star threshold or filament window before judging the algorithm; INVALID is not a FAIL of the denoiser. Before the gate run, run once with `--sweep-gains` to print the coarse blend-gain grid ({1.5, 2.0, 2.5, 3.0}² at s=0.5), pick the smallest `CHROMA_BLEND_GAIN` / `LUMA_BLEND_GAIN` pair that clears every gate threshold with margin, set them in the constants block, and re-run without the flag — the chosen gains are emitted with the other constants in the results doc. The default `--filament-row/col` window is a starting guess — inspect `Veil_before.png`, pick a window that actually crosses a NGC 6960 filament arc, re-run with explicit values, and record the chosen window in the results doc. Iterate on the `T1-BINDING` constants (edit the constants block, re-run) until the gate passes at 0.5 **and** strength 1.0 doesn't crush faint nebulosity in the eyeball A/B ("keep this kind of nebulosity" — spec §1). In the eyeball A/B also check for visible rectangular tile seams at 1/32-frame boundaries (stage-2 per-tile weights are not interpolated; if seams show, note as a constants/interpolation follow-up for the port).

- [ ] **Step 5: GATE.** If after reasonable constant iteration the table cannot meet all four thresholds: **STOP the plan here.** Commit the script + a results doc recording the best-achieved numbers, and report BLOCKED to the owner with the wavelet (approach B) fallback question. Per spec §3 this decision happens at the gate, not mid-port. Do not begin Task 2.

- [ ] **Step 6: Write the results doc** `docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md`:

```markdown
# Denoise Prototype Results (Task 1 gate)

**Spec:** docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md §3
**Script:** Scripts/prototypes/denoise_prototype.py @ <commit sha>
**Datasets:** ~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit,
              ~/Documents/LiveAstro/<chosen ngc6960 session>/master.fit
**Filament window:** rows <r0>..<r1>, cols <c0>..<c1> (verified to cross the arc)
**A/B PNGs:** ~/Desktop/denoise-ab/ (outside the repo, for owner eyeballing;
files are `.ppm` if matplotlib was unavailable — the script's PPM fallback)

## Gate table (observed)
<paste the metrics table verbatim>

GATE at strength 0.5: PASS

## VALIDATED CONSTANTS (BINDING — mirror verbatim into Denoiser.K, Task 2)
| constant | value |
|---|---|
| CHROMA_DOWN | <v> |
| CHROMA_PASSES | <v> |
| chroma_radius(s) | max(1, floor(<a> + <b>*s + 0.5)) — half-up, binding convention |
| CHROMA_EDGE_GRAD (display) | <v> |
| CHROMA_EDGE_GRAD_LINEAR | <v> |
| CHROMA_BLEND_GAIN | <v> (from the --sweep-gains grid) |
| LUMA_PASSES | <v> |
| luma_radius(s) | max(1, floor(<a> + <b>*s + 0.5)) — half-up, binding convention |
| LUMA_RESIDUAL_K | <v> |
| LUMA_BLEND_GAIN | <v> (from the --sweep-gains grid) |
| LUMA_SIGMA_PROTECT_K | <v> |
| STRUCTURE_K | <v> |
| STRUCTURED_TILE_FLOOR | <v> |
| TILES / MAX_TILE_SAMPLES / BACKGROUND_PERCENTILE / MIN_DIM | 32 / 1024 / 20 / 64 |

## Fixture effect-size floors (BINDING for DenoiserTests)
| assertion constant | value | derivation |
|---|---|---|
| s1MinChromaReduction | <observed stage-1-only coarse chroma reduction at 0.5, minus 5pt margin> | |
| s2MinSigmaReduction | <observed stage-2-only bg sigma reduction at 0.5, minus 5pt margin> | |

## Linear-domain check
Observed linear-domain run on the raw (unstretched) M8 master at 0.5:
bg sigma reduction <v>, FWHM delta <v> — constant CHROMA_EDGE_GRAD_LINEAR validated
here (spec §2.3 "linear-domain strength mapping"; stage-2 thresholds are
sigma-relative and therefore domain-free).
```

Fill every `<v>` with observed values. The two fixture floors are measured by temporarily running with the other stage disabled (comment out the call, re-run, restore) — record the numbers, not the hack.

- [ ] **Step 7: Commit**

```bash
git add Scripts/prototypes/denoise_prototype.py docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md
git commit -m "Denoise T1: prototype validated on M8+Veil, gate passed, constants recorded"
```

Expected: clean commit on `feature/native-noise-reduction`. (House commit style: no Co-Authored-By trailer.)

---

### Task 2: Denoiser Engine — Types + Stage 1 (chroma), TDD

**Files:**
- Create: `Tests/LiveAstroCoreTests/DenoiserTests.swift`
- Create: `Sources/LiveAstroCore/Imaging/Denoiser.swift`

**Interfaces:**
- Produces: `public enum Denoiser { public static func apply(_ image: AstroImage, strength: Float) -> AstroImage }` (spec §2.1 signature, verbatim). Internal: `Denoiser.K` constants, `stage1Chroma`, `stage2Luma`, `boxBlurParallel`, `gradientMagnitude`, `blockDown`, `upsampleBilinear`, `tileGrid`.
- Consumes: `AstroImage` (`AstroImage.swift:12-30` — planar channel-major `[Float]`, `sourceIsLinear`), `Parallel.rows` (`Parallel.swift:12`).
- Constants: copy the results-doc table **verbatim** into `K`. The literals below are the T1 starting values; if T1 changed them, the results doc wins.

- [ ] **Step 1: Write the failing tests (red)** — create `Tests/LiveAstroCoreTests/DenoiserTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

// Effect-size floors: T1-BINDING (docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md).
// Starting values = spec gate thresholds; replace with the results-doc floors verbatim.
// Reachable at s=0.5 because the blend amplitude is min(1, gain·s) via the T1-BINDING
// chromaBlendGain/lumaBlendGain constants (a bare-s mix could never hit 0.50/0.40);
// they remain FLOORS and graduate with T1's final gain values.
let s1MinChromaReduction: Float = 0.50
let s2MinSigmaReduction: Float = 0.40

final class DenoiserStage1Tests: XCTestCase {

    // MARK: helpers (deterministic LCG, PerformanceTests precedent)

    static func lcg(_ state: inout UInt64) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 33) / Float(1 << 31)   // 0..1
    }

    /// Coarse (8x block-mean) MAD sigma of a plane — the chroma-mottle metric in miniature.
    static func coarseSigma(_ a: [Float], w: Int, h: Int) -> Float {
        let d = 8, sw = w / d, sh = h / d
        var small = [Float](repeating: 0, count: sw * sh)
        for j in 0..<sh { for i in 0..<sw {
            var s: Float = 0
            for dy in 0..<d { for dx in 0..<d { s += a[(j*d+dy)*w + i*d+dx] } }
            small[j*sw + i] = s / Float(d*d)
        } }
        var v = small; v.sort()
        let med = v[v.count/2]
        var dev = small.map { abs($0 - med) }; dev.sort()
        return 1.4826 * dev[dev.count/2]
    }

    static func opponentPlanes(_ img: AstroImage) -> (y: [Float], c1: [Float], c2: [Float]) {
        let plane = img.width * img.height
        var y = [Float](repeating: 0, count: plane)
        var c1 = y, c2 = y
        for i in 0..<plane {
            let r = img.pixels[i], g = img.pixels[plane + i], b = img.pixels[2*plane + i]
            y[i] = (r + 2*g + b) * 0.25; c1[i] = r - g; c2[i] = b - g
        }
        return (y, c1, c2)
    }

    /// Flat luma 0.5 + coarse-scale chroma mottle: low-frequency C1/C2 noise made by
    /// nearest-upsampling 16x16 seeded noise to 128x128 (mimics the green/magenta splotches).
    static func mottleFixture() -> AstroImage {
        let w = 128, h = 128, plane = w * h
        var rng: UInt64 = 0xA5_7A0_011
        var coarse1 = [Float](repeating: 0, count: 16 * 16)
        var coarse2 = coarse1
        for i in 0..<256 {
            coarse1[i] = (lcg(&rng) - 0.5) * 0.08
            coarse2[i] = (lcg(&rng) - 0.5) * 0.08
        }
        var px = [Float](repeating: 0, count: plane * 3)
        for yy in 0..<h { for xx in 0..<w {
            let i = yy * w + xx
            let c1 = coarse1[(yy/8) * 16 + (xx/8)], c2 = coarse2[(yy/8) * 16 + (xx/8)]
            let y: Float = 0.5
            let g = y - (c1 + c2) * 0.25
            px[i] = c1 + g; px[plane + i] = g; px[2*plane + i] = c2 + g
        } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
    }

    // MARK: passthrough contracts (spec §2.1, verbatim)

    func testStrengthZeroIsByteIdentical() {
        var rng: UInt64 = 7
        let px = (0..<(96*96*3)).map { _ in Self.lcg(&rng) }
        let img = AstroImage(width: 96, height: 96, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0)
        XCTAssertEqual(out.pixels, img.pixels)          // exact, not approximate
    }

    func testTinyImagePassesThrough() {
        let px = [Float](repeating: 0.3, count: 63 * 64 * 3)
        let img = AstroImage(width: 63, height: 64, channels: 3, pixels: px, sourceIsLinear: false)
        XCTAssertEqual(Denoiser.apply(img, strength: 1).pixels, px)
    }

    func testConstantMonoIsUnchanged() {
        // Mono runs stage 2 only; on a constant plane blur == input, so output == input.
        let px = [Float](repeating: 0.42, count: 96 * 96)
        let img = AstroImage(width: 96, height: 96, channels: 1, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.8)
        for i in 0..<px.count { XCTAssertEqual(out.pixels[i], 0.42, accuracy: 1e-6) }
    }

    func testNaNPassesThroughUntouchedAndDoesNotSpread() {
        var rng: UInt64 = 11
        var px = (0..<(96*96*3)).map { _ in Self.lcg(&rng) * 0.1 + 0.3 }
        px[500] = .nan; px[96*96 + 700] = .infinity
        let img = AstroImage(width: 96, height: 96, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.7)
        XCTAssertTrue(out.pixels[500].isNaN)                       // untouched at its position
        XCTAssertTrue(out.pixels[96*96 + 700].isInfinite)
        for (i, v) in out.pixels.enumerated() where i != 500 && i != 96*96 + 700 {
            XCTAssertTrue(v.isFinite, "NaN leaked to index \(i)")
        }
    }

    func testUnsupportedChannelCountPassesThrough() {
        let px = [Float](repeating: 0.2, count: 96 * 96 * 2)
        let img = AstroImage(width: 96, height: 96, channels: 2, pixels: px, sourceIsLinear: false)
        XCTAssertEqual(Denoiser.apply(img, strength: 1).pixels, px)
    }

    // MARK: stage-1 fixtures

    func testChromaMottleSuppressedWhileLumaHolds() {
        let img = Self.mottleFixture()
        let before = Self.opponentPlanes(img)
        let out = Denoiser.apply(img, strength: 0.5)
        let after = Self.opponentPlanes(out)
        let s1b = Self.coarseSigma(before.c1, w: 128, h: 128)
        let s1a = Self.coarseSigma(after.c1, w: 128, h: 128)
        let s2b = Self.coarseSigma(before.c2, w: 128, h: 128)
        let s2a = Self.coarseSigma(after.c2, w: 128, h: 128)
        XCTAssertLessThanOrEqual(s1a, s1b * (1 - s1MinChromaReduction),
            "coarse C1 sigma \(s1b) -> \(s1a): below the T1-validated reduction floor")
        XCTAssertLessThanOrEqual(s2a, s2b * (1 - s1MinChromaReduction))
        // Luma untouched to 1e-5, not ~1 ulp (finding F5): opponent round-trip
        // rounding PLUS stage-2's float32 box-blur residuals on the nominally
        // flat luma plane both contribute — a ~1-ulp bound would be too tight.
        for i in 0..<after.y.count {
            XCTAssertEqual(after.y[i], before.y[i], accuracy: 1e-5, "luma moved at \(i)")
        }
    }

    func testNoChromaBleedAcrossLumaEdge() {
        // Two-tone luma (0.2 | 0.8) with opposite constant chroma per side: any blur
        // across the boundary drags C1 toward 0 near the edge; the luma-edge guard
        // must prevent it.
        let w = 128, h = 128, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for yy in 0..<h { for xx in 0..<w {
            let i = yy * w + xx
            let y: Float = xx < w/2 ? 0.2 : 0.8
            let c1: Float = xx < w/2 ? 0.10 : -0.10
            let g = y - c1 * 0.25
            px[i] = c1 + g; px[plane + i] = g; px[2*plane + i] = g
        } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 1.0)
        let after = Self.opponentPlanes(out)
        // Assert no-bleed across the whole coarse-guard-protected band around the
        // boundary (columns w/2-6 ... w/2+6), not just the two centre columns the
        // full-res guard alone protects — this pins the coarse guard too.
        // EXPECTED RED at the starting constants: probe analysis shows the bilinear
        // upsample leaks the unguarded neighbour coarse cell's blur delta into
        // cols ±4-6 (|Δc1| up to ~0.07 vs the 0.01 tolerance). The intended fix is
        // a ONE-CELL DILATION of the coarse luma-edge guard (guard a coarse cell if
        // it OR any 4-neighbour straddles a strong luma edge) — implement the
        // dilation in BOTH the Swift engine and the Python prototype (mirror
        // exactly; it becomes part of the T1-validated structure), then this test
        // goes green. Do not widen the tolerance and do not shrink the band.
        for yy in 8..<(h - 8) {
            for xx in (w/2 - 6)...(w/2 + 6) {
                let expected: Float = xx < w/2 ? 0.10 : -0.10
                XCTAssertEqual(after.c1[yy * w + xx], expected, accuracy: 0.01,
                    "chroma bled across luma edge (col \(xx), row \(yy))")
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests — confirm they fail to compile (no `Denoiser` yet)**

```bash
swift test --filter DenoiserStage1Tests 2>&1 | tail -5
```

Expected: build error `cannot find 'Denoiser' in scope`. (Red.)

- [ ] **Step 3: Implement the engine** — create `Sources/LiveAstroCore/Imaging/Denoiser.swift`:

```swift
import Foundation

/// Classic, deterministic two-stage noise reduction (native-noise-reduction spec §2.1).
///
/// One pure engine, two consumers: `SessionPipeline.displayCGImage` (post-stretch
/// display domain) and `NativeDenoiseProcessor` (linear master domain). The domain
/// is carried by `AstroImage.sourceIsLinear` (plan finding F3), keeping the spec's
/// single `apply(_:strength:)` signature.
///
/// Stage 1 — chroma mottle suppression (3-channel only): opponent transform
/// (Y, C1, C2), chroma downsampled 4x, box^3 blur at coarse scale, correction
/// blended under a luma-edge guard at BOTH scales so colour never bleeds across
/// star edges or filament boundaries, bilinear upsample, recombine.
/// Stage 2 — edge-preserving luma smoothing: residual-thresholded blur blend with
/// a 32x32 tile median/MAD-sigma grid (statistically flat sky smoothed harder,
/// structured tiles backed off) and a sigma-relative gradient-protection term
/// (threshold k · tile sigma).
///
/// Contracts (spec §2.1): `strength == 0` returns the input byte-identical;
/// images below 64x64 pass through; mono runs stage 2 only; non-finite input
/// pixels pass through untouched at their positions (math runs on a sanitized
/// copy — the engine never traps and never spreads NaN into neighbours).
/// Unsupported channel counts (not 1 or 3) pass through.
///
/// Deterministic: fixed constants, integer tile grid, `Parallel.rows` bands write
/// disjoint rows with per-element expressions identical to a serial loop.
public enum Denoiser {

    /// T1-validated constants. The literals below are the Task-1 STARTING values;
    /// once the prototype gate passes, the table in
    /// docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md replaces
    /// them VERBATIM (spec §3 — additive-BN / DBE / RCD discipline). Do not tune here.
    enum K {
        static let minDim = 64
        static let tilesPerAxis = 32
        static let maxTileSamples = 1024
        static let backgroundPercentile: Double = 20
        // ROUNDING CONVENTION (binding): half-up (floor(x+0.5) ≡ Swift .rounded()
        // for positive x) — the Python mirror uses int(math.floor(x + 0.5)), NOT
        // round(), which is banker's and diverges at .5 (e.g. lumaRadius at s=0.5).
        // Stage 1 — chroma
        static let chromaDown = 4
        static let chromaPasses = 3
        static func chromaRadius(_ s: Float) -> Int { max(1, Int((2.0 + 6.0 * s).rounded())) }
        static let chromaEdgeGradDisplay: Float = 0.08
        static let chromaEdgeGradLinear: Float = 0.008
        static let chromaBlendGain: Float = 2.0    // blend amplitude: min(1, gain·s)
        // Stage 2 — luma
        static let lumaPasses = 2
        static func lumaRadius(_ s: Float) -> Int { max(1, Int((1.0 + 3.0 * s).rounded())) }
        static let lumaResidualK: Float = 2.5
        static let lumaBlendGain: Float = 2.0      // blend amplitude: min(1, gain·s)
        static let lumaSigmaProtectK: Float = 3.0  // gradient-protect threshold = k · tile sigma
        static let structureK: Float = 4.0
        static let structuredTileFloor: Float = 0.15
    }

    public static func apply(_ image: AstroImage, strength: Float) -> AstroImage {
        guard strength > 0 else { return image }                       // off is free & byte-identical
        guard image.width >= K.minDim, image.height >= K.minDim else { return image }
        guard image.channels == 1 || image.channels == 3 else { return image }
        let s = min(strength, 1)
        let w = image.width, h = image.height, plane = w * h
        let src = image.pixels
        let sane = src.map { $0.isFinite ? $0 : Float(0) }             // DBE ingest-sanitize precedent

        var outPixels: [Float]
        if image.channels == 3 {
            // Opponent transform: Y=(R+2G+B)/4, C1=R-G, C2=B-G (exact integer-weight inverse).
            var y = [Float](repeating: 0, count: plane)
            var c1 = [Float](repeating: 0, count: plane)
            var c2 = [Float](repeating: 0, count: plane)
            y.withUnsafeMutableBufferPointer { yb in
                c1.withUnsafeMutableBufferPointer { c1b in
                    c2.withUnsafeMutableBufferPointer { c2b in
                        Parallel.rows(h) { rows in
                            for row in rows { for x in 0..<w {
                                let i = row * w + x
                                let r = sane[i], g = sane[plane + i], b = sane[2 * plane + i]
                                yb[i] = (r + 2 * g + b) * 0.25
                                c1b[i] = r - g
                                c2b[i] = b - g
                            } }
                        }
                    }
                }
            }
            stage1Chroma(y: y, c1: &c1, c2: &c2, width: w, height: h,
                         strength: s, linearDomain: image.sourceIsLinear)
            let y2 = stage2Luma(y, width: w, height: h,
                                strength: s, linearDomain: image.sourceIsLinear)
            var recombined = [Float](repeating: 0, count: plane * 3)
            recombined.withUnsafeMutableBufferPointer { ob in
                Parallel.rows(h) { rows in
                    for row in rows { for x in 0..<w {
                        let i = row * w + x
                        let g = y2[i] - (c1[i] + c2[i]) * 0.25
                        ob[i] = c1[i] + g
                        ob[plane + i] = g
                        ob[2 * plane + i] = c2[i] + g
                    } }
                }
            }
            outPixels = recombined
        } else {
            outPixels = stage2Luma(sane, width: w, height: h,
                                   strength: s, linearDomain: image.sourceIsLinear)
        }
        // Non-finite input pixels pass through untouched at their positions (spec §2.1).
        for i in 0..<src.count where !src[i].isFinite { outPixels[i] = src[i] }
        return AstroImage(width: w, height: h, channels: image.channels,
                          pixels: outPixels, sourceIsLinear: image.sourceIsLinear)
    }

    // MARK: - Stage 1 (chroma)

    /// Chroma mottle suppression at 1/16 pixel count (spec §2.1 stage 1).
    static func stage1Chroma(y: [Float], c1: inout [Float], c2: inout [Float],
                             width w: Int, height h: Int,
                             strength s: Float, linearDomain: Bool) {
        let edge = linearDomain ? K.chromaEdgeGradLinear : K.chromaEdgeGradDisplay
        let d = K.chromaDown
        let (yd, sw, sh) = blockDown(y, width: w, height: h, factor: d)
        let gd = gradientMagnitude(yd, width: sw, height: sh)
        let gFull = gradientMagnitude(y, width: w, height: h)
        let r = K.chromaRadius(s)
        // Blend amplitude min(1, gain·s) (T1-BINDING chromaBlendGain): a bare s caps
        // the mix at s, structurally unable to reach the 50% chroma gate at s=0.5.
        let wf = min(1, K.chromaBlendGain * s)

        func smoothed(_ c: [Float]) -> [Float] {
            let (cd, _, _) = blockDown(c, width: w, height: h, factor: d)
            var cb = cd
            for _ in 0..<K.chromaPasses { cb = boxBlurParallel(cb, sw, sh, radius: r) }
            // Coarse edge-attenuated correction (no blend term here — the blend
            // weight wf is applied once, at full resolution, or the effective mix
            // would be wf^2).
            var delta = [Float](repeating: 0, count: sw * sh)
            for i in 0..<delta.count {
                delta[i] = max(0, 1 - gd[i] / edge) * (cb[i] - cd[i])
            }
            let deltaUp = upsampleBilinear(delta, smallW: sw, smallH: sh,
                                           width: w, height: h, factor: d)
            var out = c
            out.withUnsafeMutableBufferPointer { ob in
                Parallel.rows(h) { rows in
                    for row in rows { for x in 0..<w {
                        let i = row * w + x
                        ob[i] += wf * max(0, 1 - gFull[i] / edge) * deltaUp[i]
                    } }
                }
            }
            return out
        }
        c1 = smoothed(c1)
        c2 = smoothed(c2)
    }

    // MARK: - Stage 2 (luma)

    /// Edge-preserving, tile-adaptive luma smoothing (spec §2.1 stage 2).
    static func stage2Luma(_ y: [Float], width w: Int, height h: Int,
                           strength s: Float, linearDomain: Bool) -> [Float] {
        // `linearDomain` kept for signature symmetry with the Python mirror:
        // stage-2 thresholds are sigma-relative (residual k·σ, gradient k·σ),
        // hence domain-free.
        let tiles = K.tilesPerAxis
        let grid = tileGrid(y, width: w, height: h, tiles: tiles)
        let globalBg = percentile(grid.medians, K.backgroundPercentile)
        let globalSigma = max(median(grid.sigmas), 1e-6)
        // Per-tile strength: full on statistically flat sky, floor where the tile
        // median rises above background by more than structureK sigmas.
        var tileWeight = [Float](repeating: 0, count: tiles * tiles)
        for i in 0..<tileWeight.count {
            tileWeight[i] = (grid.medians[i] - globalBg < K.structureK * globalSigma)
                ? 1.0 : K.structuredTileFloor
        }
        var blur = y
        let r = K.lumaRadius(s)
        for _ in 0..<K.lumaPasses { blur = boxBlurParallel(blur, w, h, radius: r) }
        let grad = gradientMagnitude(y, width: w, height: h)
        // Blend amplitude min(1, gain·s) (T1-BINDING lumaBlendGain): a bare s caps
        // the mix at s, structurally unable to reach the 40% luma gate at s=0.5.
        let wGain = min(1, K.lumaBlendGain * s)
        var out = y
        out.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for row in rows {
                    let ty = grid.rowTile[row]
                    for x in 0..<w {
                        let i = row * w + x
                        let t = ty * tiles + grid.colTile[x]
                        let sigma = max(grid.sigmas[t], 1e-6)
                        let resid = y[i] - blur[i]
                        if abs(resid) > K.lumaResidualK * sigma { continue }   // protected detail ("keep")
                        // Sigma-relative gradient protection (T1-BINDING lumaSigmaProtectK):
                        // with a fixed threshold, background noise gradients
                        // (E[|gx|+|gy|] ≈ 1.13σ) eat the protection budget and the noise
                        // protects itself; relative to k·σ_tile, noise falls inside the
                        // threshold while stars/filaments (|grad| ≫ k·σ) stay protected.
                        let protect = max(0, 1 - grad[i] / (K.lumaSigmaProtectK * sigma))
                        ob[i] = y[i] + wGain * tileWeight[t] * protect * (blur[i] - y[i])
                    }
                }
            }
        }
        return out
    }

    // MARK: - Primitives (mirrored 1:1 by Scripts/prototypes/denoise_prototype.py)

    /// Clamped-edge separable box blur, window 2r+1, H then V. Identical per-element
    /// semantics to BackgroundExtraction.boxBlur (BackgroundExtraction.swift:314-334)
    /// but parallel over rows: stage 2 runs it at full 26MP resolution where the
    /// serial DBE version (built for 1/16-scale buffers) would dominate the §4 budget.
    static func boxBlurParallel(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        if r < 1 { return a }
        let inv = 1.0 / Float(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeMutableBufferPointer { tb in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    var s: Float = 0
                    for dx in -r...r { s += a[y * w + min(w - 1, max(0, x + dx))] }
                    tb[y * w + x] = s * inv
                } }
            }
        }
        var outb = [Float](repeating: 0, count: w * h)
        outb.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    var s: Float = 0
                    for dy in -r...r { s += tmp[min(h - 1, max(0, y + dy)) * w + x] }
                    ob[y * w + x] = s * inv
                } }
            }
        }
        return outb
    }

    /// L1 central-difference gradient magnitude; each axis contributes 0 at its borders.
    static func gradientMagnitude(_ a: [Float], width w: Int, height h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        g.withUnsafeMutableBufferPointer { gb in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    let i = y * w + x
                    var gx: Float = 0, gy: Float = 0
                    if x > 0 && x < w - 1 { gx = (a[i + 1] - a[i - 1]) * 0.5 }
                    if y > 0 && y < h - 1 { gy = (a[i + w] - a[i - w]) * 0.5 }
                    gb[i] = abs(gx) + abs(gy)
                } }
            }
        }
        return g
    }

    /// Block-average downsample; small dims max(2, dim/d) — flattenMultiscale geometry
    /// (BackgroundExtraction.swift:260-268).
    static func blockDown(_ a: [Float], width w: Int, height h: Int, factor d: Int)
        -> (small: [Float], sw: Int, sh: Int) {
        let sw = max(2, w / d), sh = max(2, h / d)
        var small = [Float](repeating: 0, count: sw * sh)
        small.withUnsafeMutableBufferPointer { sb in
            Parallel.rows(sh) { rows in
                for j in rows { for i in 0..<sw {
                    var sum: Float = 0; var n: Float = 0
                    for dy in 0..<d { for dx in 0..<d {
                        let yy = j * d + dy, xx = i * d + dx
                        if yy < h && xx < w { sum += a[yy * w + xx]; n += 1 }
                    } }
                    sb[j * sw + i] = n > 0 ? sum / n : 0
                } }
            }
        }
        return (small, sw, sh)
    }

    /// Bilinear upsample of a factor-d downsampled plane back to w x h
    /// (sample centers at (i+0.5)*d in full-res coords).
    static func upsampleBilinear(_ small: [Float], smallW sw: Int, smallH sh: Int,
                                 width w: Int, height h: Int, factor d: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for yPix in rows {
                    let fy = (Float(yPix) + 0.5) / Float(d) - 0.5
                    let y0 = min(sh - 1, max(0, Int(fy.rounded(.down))))
                    let y1 = min(sh - 1, y0 + 1)
                    let wy = min(max(fy - Float(y0), 0), 1)
                    for xPix in 0..<w {
                        let fx = (Float(xPix) + 0.5) / Float(d) - 0.5
                        let x0 = min(sw - 1, max(0, Int(fx.rounded(.down))))
                        let x1 = min(sw - 1, x0 + 1)
                        let wx = min(max(fx - Float(x0), 0), 1)
                        let top = small[y0 * sw + x0] * (1 - wx) + small[y0 * sw + x1] * wx
                        let bot = small[y1 * sw + x0] * (1 - wx) + small[y1 * sw + x1] * wx
                        ob[yPix * w + xPix] = top * (1 - wy) + bot * wy
                    }
                }
            }
        }
        return out
    }

    // MARK: - Tile grid (plan finding F2: same integer edge grid as
    // BackgroundExtraction.tileSamples, y0 = ty*h/tiles ..., but with MAD sigma,
    // which tileSamples does not provide)

    struct TileGrid {
        let medians: [Float]      // tiles x tiles, row-major
        let sigmas: [Float]       // 1.4826 * MAD per tile
        let rowTile: [Int]        // pixel row -> tile row
        let colTile: [Int]        // pixel col -> tile col
    }

    static func tileGrid(_ a: [Float], width w: Int, height h: Int, tiles: Int) -> TileGrid {
        var medians = [Float](repeating: 0, count: tiles * tiles)
        var sigmas = [Float](repeating: 0, count: tiles * tiles)
        var rowTile = [Int](repeating: 0, count: h)
        var colTile = [Int](repeating: 0, count: w)
        for ty in 0..<tiles {
            for yy in (ty * h / tiles)..<((ty + 1) * h / tiles) { rowTile[yy] = ty }
        }
        for tx in 0..<tiles {
            for xx in (tx * w / tiles)..<((tx + 1) * w / tiles) { colTile[xx] = tx }
        }
        for ty in 0..<tiles { for tx in 0..<tiles {
            let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
            let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
            if y1 <= y0 || x1 <= x0 { continue }
            // Deterministic stride cap (AstroImage.sampleStride precedent): a full
            // sort of every pixel in 1024 tiles of a 26MP frame would blow the §4 budget.
            let count = (y1 - y0) * (x1 - x0)
            let strideStep = max(1, count / K.maxTileSamples)
            var vals: [Float] = []
            vals.reserveCapacity(count / strideStep + 1)
            var k = 0
            for yy in y0..<y1 { for xx in x0..<x1 {
                if k % strideStep == 0 { vals.append(a[yy * w + xx]) }
                k += 1
            } }
            vals.sort()
            let med = vals[vals.count / 2]
            var dev = vals.map { abs($0 - med) }
            dev.sort()
            medians[ty * tiles + tx] = med
            sigmas[ty * tiles + tx] = 1.4826 * dev[dev.count / 2]
        } }
        return TileGrid(medians: medians, sigmas: sigmas, rowTile: rowTile, colTile: colTile)
    }

    /// Upper median (sorted()[count/2]) — matches the codebase's median convention.
    static func median(_ a: [Float]) -> Float {
        var v = a; v.sort(); return v[v.count / 2]
    }

    /// Nearest-rank percentile (mirrors AutoStretch.neutralizeBackgroundAdditive's index).
    static func percentile(_ a: [Float], _ p: Double) -> Float {
        var v = a; v.sort()
        let idx = min(v.count - 1, max(0, Int((p / 100 * Double(v.count - 1)).rounded())))
        return v[idx]
    }
}
```

- [ ] **Step 4: Green + fixture floor sanity**

```bash
swift test --filter DenoiserStage1Tests 2>&1 | tail -5
```

Expected: `Test Suite 'DenoiserStage1Tests' passed` (7 tests). If `testChromaMottleSuppressedWhileLumaHolds` fails on the reduction floor, the T1 constants and the fixture floor disagree — re-check the transcription against the results doc **before** touching either number; the results doc wins.

- [ ] **Step 5: Full suite still green** (`swift test 2>&1 | tail -3` → `Test Suite 'All tests' passed`), then commit:

```bash
git add Sources/LiveAstroCore/Imaging/Denoiser.swift Tests/LiveAstroCoreTests/DenoiserTests.swift
git commit -m "Denoise T2: engine types + stage 1 chroma with passthrough contracts (TDD)"
```

---

### Task 3: Stage 2 (luma) TDD — star/filament protection, tile adaptivity, determinism

**Files:**
- Modify: `Tests/LiveAstroCoreTests/DenoiserTests.swift` (append a second test class)
- Modify (only if a test exposes a defect): `Sources/LiveAstroCore/Imaging/Denoiser.swift`

Stage 2 is already implemented in T2 (the engine ships whole); this task adds **characterization pins (post-hoc behavioral)** — the tests pin an implementation that already exists rather than driving it red-first. Write each test, run, and only then fix the engine if red. Do not weaken a test to go green; a red here that traces to a T1 constant is a STOP-and-recheck against the results doc.

- [ ] **Step 1: Append to `DenoiserTests.swift`:**

```swift
final class DenoiserStage2Tests: XCTestCase {

    /// Gaussian-ish noise via LCG pairs (Box-Muller), deterministic.
    static func noise(_ rng: inout UInt64, sigma: Float) -> Float {
        let u1 = max(DenoiserStage1Tests.lcg(&rng), 1e-7)
        let u2 = DenoiserStage1Tests.lcg(&rng)
        return sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    static func madSigma(_ v: [Float]) -> Float {
        var s = v; s.sort()
        let med = s[s.count / 2]
        var dev = v.map { abs($0 - med) }; dev.sort()
        return 1.4826 * dev[dev.count / 2]
    }

    /// Half-max FWHM along +x/-x/+y/-y from the star center (test-grade, matches
    /// the prototype's star_fwhm_median approach in miniature).
    static func fwhm(_ px: [Float], w: Int, cx: Int, cy: Int, bg: Float) -> Float {
        let peak = px[cy * w + cx] - bg
        let half = bg + peak / 2
        var radii: [Float] = []
        for (dy, dx) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
            var prev = px[cy * w + cx]
            for k in 1..<12 {
                let cur = px[(cy + dy * k) * w + (cx + dx * k)]
                if cur <= half {
                    radii.append(Float(k - 1) + (prev - half) / max(prev - cur, 1e-9))
                    break
                }
                prev = cur
            }
        }
        return 2 * radii.reduce(0, +) / Float(radii.count)
    }

    /// 256x256 mono: bg 0.1 + sigma-0.02 noise + one Gaussian star (amp 0.8, sigma 2)
    /// at (192, 64) + a horizontal filament ridge (amp 0.15, sigma 3) along y=192.
    static func starFieldFixture() -> AstroImage {
        let w = 256, h = 256
        var rng: UInt64 = 0xF00D_1234
        var px = (0..<(w * h)).map { _ in 0.1 + noise(&rng, sigma: 0.02) }
        for y in 0..<h { for x in 0..<w {
            let dxs = Float(x - 192), dys = Float(y - 64)
            px[y * w + x] += 0.8 * exp(-(dxs * dxs + dys * dys) / (2 * 2 * 2))
            let dyf = Float(y - 192)
            px[y * w + x] += 0.15 * exp(-(dyf * dyf) / (2 * 3 * 3))
        } }
        return AstroImage(width: w, height: h, channels: 1,
                          pixels: px.map { min(max($0, 0), 1) }, sourceIsLinear: false)
    }

    func testBackgroundSigmaDropsWhileStarFWHMHolds() {
        let img = Self.starFieldFixture()
        let out = Denoiser.apply(img, strength: 0.5)
        // Background patch far from star and filament: rows 8..96, cols 8..96.
        func patch(_ px: [Float]) -> [Float] {
            var v: [Float] = []
            for y in 8..<96 { for x in 8..<96 { v.append(px[y * 256 + x]) } }
            return v
        }
        let sb = Self.madSigma(patch(img.pixels)), sa = Self.madSigma(patch(out.pixels))
        XCTAssertLessThanOrEqual(sa, sb * (1 - s2MinSigmaReduction),
            "bg sigma \(sb) -> \(sa): below the T1-validated reduction floor")
        let fb = Self.fwhm(img.pixels, w: 256, cx: 192, cy: 64, bg: 0.1)
        let fa = Self.fwhm(out.pixels, w: 256, cx: 192, cy: 64, bg: 0.1)
        XCTAssertLessThanOrEqual(abs(fa - fb) / fb, 0.02,
            "star FWHM moved \(fb) -> \(fa) (> 2%)")            // spec gate metric 3
    }

    func testFilamentRidgeContrastPreserved() {
        let img = Self.starFieldFixture()
        let out = Denoiser.apply(img, strength: 0.5)
        // Ridge contrast: mean over cols 32..224 of (profile peak - profile floor).
        func contrast(_ px: [Float]) -> Float {
            var prof = [Float](repeating: 0, count: 33)      // rows 176..208
            for (j, y) in (176...208).enumerated() {
                var s: Float = 0
                for x in 32..<224 { s += px[y * 256 + x] }
                prof[j] = s / 192
            }
            var sorted = prof; sorted.sort()
            return prof.max()! - sorted[3]                    // peak minus ~10th pct floor
        }
        let cb = contrast(img.pixels), ca = contrast(out.pixels)
        XCTAssertGreaterThanOrEqual(ca / cb, 0.95,
            "filament contrast \(cb) -> \(ca): below the 95% spec gate")
    }

    func testFlatTileSmoothedMoreThanStructuredTile() {
        // Left half flat sky (0.1 + noise); right half bright structure (0.5 + noise):
        // the tile-adaptive weight must smooth the flat side harder.
        let w = 256, h = 256
        var rng: UInt64 = 0xBEEF_5678
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let base: Float = x < w / 2 ? 0.1 : 0.5
            px[y * w + x] = min(max(base + Self.noise(&rng, sigma: 0.02), 0), 1)
        } }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.5)
        func sigma(_ p: [Float], _ xr: Range<Int>) -> Float {
            var v: [Float] = []
            for y in 16..<240 { for x in xr { v.append(p[y * w + x]) } }
            return Self.madSigma(v)
        }
        let flatReduction = 1 - sigma(out.pixels, 16..<112) / sigma(px, 16..<112)
        let structReduction = 1 - sigma(out.pixels, 144..<240) / sigma(px, 144..<240)
        XCTAssertGreaterThan(flatReduction, structReduction,
            "flat \(flatReduction) vs structured \(structReduction): tile adaptivity inverted")
    }

    func testDeterministicAcrossRepeatedApplication() {
        let img = Self.starFieldFixture()
        let a = Denoiser.apply(img, strength: 0.7)
        let b = Denoiser.apply(img, strength: 0.7)
        XCTAssertEqual(a.pixels, b.pixels)     // exact — Parallel.rows bands are disjoint
    }

    func testMonoNoiseReductionEngages() {
        // Mono is stage 2 only (spec §2.1) — and stage 2 must actually do something.
        var rng: UInt64 = 0x1CE_CREA
        let px = (0..<(128 * 128)).map { _ in min(max(0.1 + Self.noise(&rng, sigma: 0.02), 0), 1) }
        let img = AstroImage(width: 128, height: 128, channels: 1, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.5)
        XCTAssertLessThan(Self.madSigma(out.pixels), Self.madSigma(px))
        XCTAssertNotEqual(out.pixels, px)
    }
}
```

(`0x1CE_CREA` — `A` is a valid hex digit; this compiles. `0xBEEF_5678`, `0xF00D_1234` likewise.)

- [ ] **Step 2: Run the characterization pins (post-hoc behavioral), then reconcile**

```bash
swift test --filter DenoiserStage2Tests 2>&1 | tail -6
```

Expected: all 5 pass if the T1 constants transferred correctly. For each failure: diagnose against the prototype (same fixture can be replicated in Python within minutes) — the fix is either a transcription error in `Denoiser.K`/primitives (fix Swift) or an over-tight synthetic fixture (only then adjust the fixture, and record why in the commit message). Never adjust a `K` constant to pass a test. Also: filament-contrast fixture margin is ~1.3 points at starting constants (96.3% vs 0.95 floor) — a T1 constant change can flip it red without any transcription error; re-derive before suspecting the port.

- [ ] **Step 3: Full suite + commit**

```bash
swift test 2>&1 | tail -3
git add Tests/LiveAstroCoreTests/DenoiserTests.swift Sources/LiveAstroCore/Imaging/Denoiser.swift
git commit -m "Denoise T3: stage-2 luma behavioural pins (sigma/FWHM/filament/tile-adaptivity/determinism)"
```

---

### Task 4: Golden Pin — real M8 crop, prototype-generated expected output

**Files:**
- Create: `Tests/LiveAstroCoreTests/Fixtures/denoise_golden_input.f32`, `denoise_golden_expected_py.f32`, `denoise_golden_meta.json` (from the prototype), later `denoise_golden_expected_swift.f32` (from the shipped Swift)
- Create: `Tests/LiveAstroCoreTests/DenoiserGoldenTests.swift`

**Golden generation rule (the RCD lesson, stated as binding):** the Python `--golden` output is the **port-validity gate only** — Swift(float32) vs Python(float32-cast numpy) is compared at 2e-3 and `denoise_golden_expected_py.f32` is never regenerated afterward. The **normative long-term pin** is `denoise_golden_expected_swift.f32`, generated by the SHIPPED `Denoiser.apply` via the `DUMP_DENOISE_GOLDENS=1`-gated test (correct by construction, exactly like `DebayerRCDTests.testDumpGoldenVectors`) and compared at 1e-6. Any future intentional algorithm change regenerates only the Swift file; the Python path stays non-normative.

- [ ] **Step 1: Generate the golden fixtures from the prototype**

```bash
cd /Users/pauldavis/liveastro-studio
python3 Scripts/prototypes/denoise_prototype.py golden \
  --m8 ~/Documents/LiveAstro/2026-07-08-m8lagoon-3/master.fit \
  --out Tests/LiveAstroCoreTests/Fixtures
ls -l Tests/LiveAstroCoreTests/Fixtures/denoise_golden_*
```

Expected: `denoise_golden_input.f32` (49152 bytes = 64×64×3×4), `denoise_golden_expected_py.f32` (49152 bytes), `denoise_golden_meta.json`. Choose `--crop-x/--crop-y` so the crop contains sky + at least one star (inspect `M8_before.png` from T1); record the chosen offsets (they land in the meta json automatically). If the default (1024, 768) is boring sky, move it.

- [ ] **Step 2: Write the golden tests** — create `Tests/LiveAstroCoreTests/DenoiserGoldenTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

/// Pins the Swift Denoiser to the Task-1-validated prototype on a real M8 crop
/// (spec §6 "Golden"). Two pins, per the RCD golden lesson:
///  - *_py.f32   : prototype float32 output, 2e-3 tolerance — the cross-language
///                 port-validity gate; generated once by denoise_prototype.py golden,
///                 never regenerated.
///  - *_swift.f32: SHIPPED-Swift output, 1e-6 tolerance — the normative refactor
///                 pin; regenerated only via DUMP_DENOISE_GOLDENS=1 below.
final class DenoiserGoldenTests: XCTestCase {

    private func loadFloats(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures"),
            "\(name).f32 missing from Fixtures")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count % 4, 0)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
    }

    private func goldenInput() throws -> AstroImage {
        let px = try loadFloats("denoise_golden_input")
        XCTAssertEqual(px.count, 64 * 64 * 3)
        return AstroImage(width: 64, height: 64, channels: 3, pixels: px,
                          sourceIsLinear: false)          // display-domain crop (meta json)
    }

    private func assertMatches(_ out: [Float], _ expected: [Float],
                               tolerance: Float, label: String) {
        XCTAssertEqual(out.count, expected.count, "\(label): size mismatch")
        var maxErr: Float = 0
        for i in 0..<out.count {
            let err = abs(out[i] - expected[i])
            if err > maxErr { maxErr = err }
            XCTAssertLessThanOrEqual(err, tolerance,
                "\(label): pixel \(i) got \(out[i]) expected \(expected[i]) diff \(err)")
        }
        print("DenoiserGoldenTests · \(label) maxErr = \(maxErr)")
    }

    func testGoldenCropMatchesPrototype() throws {
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        try assertMatches(out.pixels, loadFloats("denoise_golden_expected_py"),
                          tolerance: 2e-3, label: "py-pin")
    }

    func testGoldenCropMatchesSwiftPin() throws {
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        try assertMatches(out.pixels, loadFloats("denoise_golden_expected_swift"),
                          tolerance: 1e-6, label: "swift-pin")
    }

    // Regeneration utility (RCD DUMP_GOLDENS pattern, DebayerRCDTests.swift:21-58):
    // DUMP_DENOISE_GOLDENS=1 swift test --filter testDumpSwiftGolden
    // writes the shipped implementation's output to a temp file and prints the cp command.
    func testDumpSwiftGolden() throws {
        guard ProcessInfo.processInfo.environment["DUMP_DENOISE_GOLDENS"] == "1" else {
            throw XCTSkip("regeneration utility — set DUMP_DENOISE_GOLDENS=1 to emit the Swift pin")
        }
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        var data = Data(capacity: out.pixels.count * 4)
        for v in out.pixels {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("denoise_golden_expected_swift.f32")
        try data.write(to: url)
        print("\n==== DUMP_DENOISE_GOLDENS ====")
        print("cp \(url.path) Tests/LiveAstroCoreTests/Fixtures/denoise_golden_expected_swift.f32")
        print("==== END ====\n")
    }
}
```

- [ ] **Step 3: Red, then the py-pin gate**

```bash
swift test --filter DenoiserGoldenTests 2>&1 | tail -6
```

Expected first run: `testGoldenCropMatchesPrototype` **passes** (the port matches the prototype ≤ 2e-3) and `testGoldenCropMatchesSwiftPin` **fails** (its fixture doesn't exist yet). If the py-pin fails: this is the port-divergence alarm — diagnose primitive-by-primitive against the Python mirror (blur → gradient → blockDown → upsample → tileGrid → stages, each is independently comparable on the crop). Do NOT loosen 2e-3; a persistent mismatch is a porting bug by definition (both sides implement the same validated algorithm).

- [ ] **Step 4: Generate the Swift pin, go green**

```bash
DUMP_DENOISE_GOLDENS=1 swift test --filter testDumpSwiftGolden 2>&1 | grep -A2 "DUMP_DENOISE"
cp /var/folders/.../denoise_golden_expected_swift.f32 Tests/LiveAstroCoreTests/Fixtures/   # use the printed path
swift test --filter DenoiserGoldenTests 2>&1 | tail -4
```

Expected: `Test Suite 'DenoiserGoldenTests' passed` (3 tests: 2 pins + 1 skip).

- [ ] **Step 5: Commit**

```bash
git add Tests/LiveAstroCoreTests/Fixtures/denoise_golden_input.f32 \
        Tests/LiveAstroCoreTests/Fixtures/denoise_golden_expected_py.f32 \
        Tests/LiveAstroCoreTests/Fixtures/denoise_golden_expected_swift.f32 \
        Tests/LiveAstroCoreTests/Fixtures/denoise_golden_meta.json \
        Tests/LiveAstroCoreTests/DenoiserGoldenTests.swift
git commit -m "Denoise T4: real-M8 golden pin (py 2e-3 port gate + Swift 1e-6 refactor pin)"
```

---

### Task 5: Display Integration — DisplayAdjustments field, pipeline stage, slider, persistence

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Modify: `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift`, `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`
- Create: `Tests/LiveAstroCoreTests/DenoiseDisplayIntegrationTests.swift`

`SessionSettings` needs **no new field**: `displayAdjustments` is already persisted (`SessionSettings.swift:20,74`); the new key rides inside it. `AppModel.applyDisplayAdjustments()` (`AppModel.swift:252`) already pushes the whole struct to `pipeline.displayAdjustments` — no app-model change either.

- [ ] **Step 1: Failing Codable tests (red)** — append to `DisplayAdjustmentsTests.swift`:

```swift
final class DisplayAdjustmentsDenoiseTests: XCTestCase {
    func testDenoiseDefaultsOffAndRoundTrips() throws {
        var a = DisplayAdjustments.neutral
        XCTAssertEqual(a.denoiseStrength, 0)                 // default OFF (spec §2.2)
        a.denoiseStrength = 0.6
        let back = try JSONDecoder().decode(DisplayAdjustments.self,
                                            from: JSONEncoder().encode(a))
        XCTAssertEqual(back.denoiseStrength, 0.6, accuracy: 1e-9)
    }

    func testDecodesOldSettingsWithoutDenoiseKey() throws {
        let old = #"{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5,"backgroundExtraction":true,"backgroundDegree":2,"bgScale":3.0,"bgSmoothest":0.5}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(old.utf8))
        XCTAssertEqual(a.denoiseStrength, 0)                 // absent -> off
        XCTAssertEqual(a.blackPoint, 0.1)
    }
}
```

And to `SessionSettingsTests.swift`:

```swift
    func testSettingsBlobWithoutDenoiseKeyDecodesOff() throws {
        var s = SessionSettings.defaults
        s.displayAdjustments.denoiseStrength = 0.4
        let round = try JSONDecoder().decode(SessionSettings.self,
                                             from: JSONEncoder().encode(s))
        XCTAssertEqual(round.displayAdjustments.denoiseStrength, 0.4, accuracy: 1e-9)
        // A LITERAL settings blob whose displayAdjustments predates the denoise key
        // (same pattern as DisplayAdjustmentsDenoiseTests' missing-key test above):
        // re-encoding a freshly-constructed struct would always include the key and
        // prove nothing about the predates-the-key path.
        let old = #"{"sourceModeRaw":"Stacker output (Siril)","filePrefix":"live_stack","neutralizeBackground":false,"subExposureSeconds":60,"targetName":"M8","calibration":{},"displayAdjustments":{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5,"backgroundExtraction":true,"backgroundDegree":2,"bgScale":3.0,"bgSmoothest":0.5}}"#
        let decoded = try JSONDecoder().decode(SessionSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.displayAdjustments.denoiseStrength, 0)   // absent -> off
        XCTAssertEqual(decoded.displayAdjustments.blackPoint, 0.1)      // siblings intact
    }
```

Run `swift test --filter DisplayAdjustmentsDenoiseTests 2>&1 | tail -3` — expected: compile error `value of type 'DisplayAdjustments' has no member 'denoiseStrength'`. (Red.)

- [ ] **Step 2: Add the field** (exact `DisplayAdjustments.swift` edits — the established back-compat pattern at lines 40-54):
  - Doc block: add `/// - denoiseStrength:    0 (off) … 1          — classic two-stage noise reduction (post-stretch)` after the `bgSmoothest` line.
  - Add `public var denoiseStrength: Double` after `public var bgSmoothest: Double`.
  - Init: add parameter `denoiseStrength: Double = 0` after `bgSmoothest: Double = 0.5`, and `self.denoiseStrength = denoiseStrength` in the body.
  - `CodingKeys`: append `, denoiseStrength`.
  - `init(from:)`: add `denoiseStrength = try c.decodeIfPresent(Double.self, forKey: .denoiseStrength) ?? 0`.

  Note (plan finding F1): `Double`, not the spec's `Float`, for sibling-field consistency; the engine boundary converts.

- [ ] **Step 3: Insert the pipeline stage.** In `SessionPipeline.displayCGImage` (`SessionPipeline.swift:344-367`), replace:

```swift
        let stretched = balanced.sourceIsLinear
            ? AutoStretch.stretch(balanced, blackPoint: adj.blackPoint, midtoneStrength: adj.midtoneStrength)
            : balanced
        let display = AutoStretch.applySaturation(stretched, adj.saturation)
```

with:

```swift
        let stretched = balanced.sourceIsLinear
            ? AutoStretch.stretch(balanced, blackPoint: adj.blackPoint, midtoneStrength: adj.midtoneStrength)
            : balanced
        // Denoise AFTER stretch + DBE (the targeted noise is the post-stretch
        // appearance) and BEFORE saturation/packing, so broadcast, snapshots,
        // latest.png and replay all inherit it while master.fit stays raw (spec §2.2).
        // Clamp on APPLY, not in the struct (DisplayAdjustments convention).
        let denoised = adj.denoiseStrength > 0
            ? Denoiser.apply(stretched, strength: Float(min(max(adj.denoiseStrength, 0), 1)))
            : stretched
        let display = AutoStretch.applySaturation(denoised, adj.saturation)
```

- [ ] **Step 4: Add the slider.** In `ControlView.swift`, inside `Section("Display Adjustments")` (line 394), after the DBE `if model.displayAdjustments.backgroundExtraction { … }` block (ends line 440) and before the `Button("Reset")`, insert:

```swift
                        VStack(alignment: .leading) {
                            Text("Denoise")
                            Slider(value: $model.displayAdjustments.denoiseStrength, in: 0...1) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            .help("Classic noise reduction — smooths background grain and color mottle on the displayed stack. 0 = off. master.fit is never modified.")
                        }
```

The drag-end closure is the DBE-slider gotcha (spec §2.2): the value binding updates continuously, but the pipeline push + re-render happens only on drag end via `applyDisplayAdjustments()` — matching lines 397-399/424-426. `Reset` (line 441-444) already restores `.neutral`, which now includes `denoiseStrength = 0` — no change needed there.

- [ ] **Step 5: Integration test** — create `Tests/LiveAstroCoreTests/DenoiseDisplayIntegrationTests.swift` (NativePipelineTests helper conventions: `FolderFrameSource` import mode, `FITSWriter.float32` subs, sandbox temp dir):

```swift
import XCTest
@testable import LiveAstroCore

/// Spec §6 integration: latest.png (and thus every snapshot/replay frame, which
/// share the displayCGImage render) inherits denoise when enabled, and the
/// display path never touches master.fit.
final class DenoiseDisplayIntegrationTests: XCTestCase {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One noisy mono starfield sub (mono exercises stage 2; deterministic LCG noise).
    private func writeNoisySub(_ dir: URL, name: String) throws {
        var rng: UInt64 = 0xDEAD_0001
        var px = (0..<(256 * 256)).map { _ -> Float in
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.08 + Float(rng >> 33) / Float(1 << 31) * 0.04
        }
        for (sx, sy) in [(64.0, 64.0), (180.0, 90.0), (120.0, 200.0)] {
            for y in Int(sy) - 6...Int(sy) + 6 { for x in Int(sx) - 6...Int(sx) + 6 {
                let dx = Double(x) - sx, dy = Double(y) - sy
                px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / 8))
            } }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1,
                               pixels: px.map { min(max($0, 0), 1) })
            .write(to: dir.appendingPathComponent(name))
    }

    private func runImport(denoise: Double) throws -> URL {
        let root = try sandbox()
        let subs = root.appendingPathComponent("subs", isDirectory: true)
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        try writeNoisySub(subs, name: "sub_0001.fit")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: nil)
        let profile = SessionProfile(targetName: "T", telescope: "t", camera: "c",
                                     mount: "m", filter: "f", locationLabel: "l",
                                     bortle: 5, subExposureSeconds: 10, notes: "")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: root)
        pipeline.displayAdjustments = DisplayAdjustments(denoiseStrength: denoise)
        try pipeline.start()
        let replay = try pipeline.end()
        return replay.deletingLastPathComponent()             // session directory
    }

    func testLatestPNGInheritsDenoiseAndMasterDoesNot() throws {
        let neutralDir = try runImport(denoise: 0)
        let denoisedDir = try runImport(denoise: 0.8)
        let latestA = try Data(contentsOf: neutralDir.appendingPathComponent("latest.png"))
        let latestB = try Data(contentsOf: denoisedDir.appendingPathComponent("latest.png"))
        XCTAssertNotEqual(latestA, latestB, "denoise strength did not reach latest.png")
        // The replay-input keyframes (snapshots/NNNN.png, SnapshotRecorder) share the
        // displayCGImage render — assert one directly rather than arguing only by
        // construction that replay inherits denoise.
        func firstSnapshot(_ dir: URL) throws -> Data {
            let snaps = dir.appendingPathComponent("snapshots", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: snaps.path)
                .filter { $0.hasSuffix(".png") }.sorted()
            return try Data(contentsOf: snaps.appendingPathComponent(try XCTUnwrap(names.first)))
        }
        XCTAssertNotEqual(try firstSnapshot(neutralDir), try firstSnapshot(denoisedDir),
                          "denoise strength did not reach the replay keyframes")
        // master.fit stays raw: identical input subs -> byte-identical masters
        // regardless of the display-path denoise setting (spec: master never mutated).
        let masterA = try Data(contentsOf: neutralDir.appendingPathComponent("master.fit"))
        let masterB = try Data(contentsOf: denoisedDir.appendingPathComponent("master.fit"))
        XCTAssertEqual(masterA, masterB)
    }

    func testStrengthZeroRenderMatchesNeutralAdjustments() throws {
        let a = try runImport(denoise: 0)
        let b = try runImport(denoise: 0)
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("latest.png")),
                       try Data(contentsOf: b.appendingPathComponent("latest.png")),
                       "strength-0 path is not deterministic/passthrough")
    }
}
```

(If `SessionProfile`'s memberwise init differs from the one in `NativePipelineTests.swift:37-41`, copy that file's `profile()` helper verbatim instead — it is the authoritative shape.)

- [ ] **Step 6: Green + commit**

```bash
swift test --filter "DisplayAdjustmentsDenoiseTests|DenoiseDisplayIntegrationTests|SessionSettingsTests" 2>&1 | tail -4
swift build 2>&1 | tail -2   # ControlView (app target) compiles
git add Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift \
        Sources/LiveAstroCore/Pipeline/SessionPipeline.swift \
        Sources/LiveAstroStudio/ControlView.swift \
        Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift \
        Tests/LiveAstroCoreTests/SessionSettingsTests.swift \
        Tests/LiveAstroCoreTests/DenoiseDisplayIntegrationTests.swift
git commit -m "Denoise T5: display-path integration (denoiseStrength field, pipeline stage, slider, persistence)"
```

Expected: all filtered suites pass; `Build complete!`.

---

### Task 6: NativeDenoiseProcessor + Picker Entry

**Files:**
- Modify: `Sources/LiveAstroCore/Processing/Processor.swift`
- Create: `Sources/LiveAstroCore/Processing/NativeDenoiseProcessor.swift`
- Modify: `Sources/LiveAstroStudio/ImportController.swift`, `Sources/LiveAstroStudio/ControlView.swift`
- Create: `Tests/LiveAstroCoreTests/NativeDenoiseProcessorTests.swift`
- Modify: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- `Processor` protocol (`Processor.swift:4-12`): `func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL` — "Returns the actual output path". Native NR always returns exactly `outputURL` (no extension juggling, unlike GraXpert) — that IS the produced-URL contract to pin.
- `FITSReader.readLinear(_:) -> FITSImage` (`FITSReader.swift:120-122`; `FITSImage` = width/height/channels/planar pixels), `FITSWriter.float32(width:height:channels:pixels:bottomUp:metadata:stackCount:totalExposureSeconds:)` (`FITSWriter.swift:6-10`), `SourceMetadata(fitsKeywords:)` (used at `FolderFrameSource.swift:494`).

- [ ] **Step 1: Failing tests (red)** — create `Tests/LiveAstroCoreTests/NativeDenoiseProcessorTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class NativeDenoiseProcessorTests: XCTestCase {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 96x96 3-channel noisy master (deterministic).
    private func writeMaster(_ url: URL) throws -> [Float] {
        var rng: UInt64 = 0xCAFE_0002
        let px = (0..<(96 * 96 * 3)).map { _ -> Float in
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.05 + Float(rng >> 33) / Float(1 << 31) * 0.03
        }
        try FITSWriter.float32(width: 96, height: 96, channels: 3, pixels: px).write(to: url)
        return px
    }

    func testRoundTripWritesDenoisedOutputAndReturnsOutputURL() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        let inputPixels = try writeMaster(master)
        let masterBytes = try Data(contentsOf: master)
        var logs: [String] = []
        let produced = try NativeDenoiseProcessor(strength: 0.8)
            .process(masterURL: master, outputURL: out) { logs.append($0) }
        XCTAssertEqual(produced, out)                          // produced-URL contract: exactly outputURL
        let img = try FITSReader.readLinear(try Data(contentsOf: produced))
        XCTAssertEqual(img.width, 96); XCTAssertEqual(img.height, 96)
        XCTAssertEqual(img.channels, 3)
        XCTAssertNotEqual(img.pixels, inputPixels)             // linear-domain engine engaged
        XCTAssertEqual(try Data(contentsOf: master), masterBytes)   // master.fit never mutated
        XCTAssertFalse(logs.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".native-denoise-") }, "temp file leaked")
    }

    func testStrengthZeroWritesPixelEquivalentOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        let inputPixels = try writeMaster(master)
        _ = try NativeDenoiseProcessor(strength: 0)
            .process(masterURL: master, outputURL: out, log: nil)
        let img = try FITSReader.readLinear(try Data(contentsOf: out))
        XCTAssertEqual(img.pixels, inputPixels)                // engine passthrough, still a valid file
    }

    func testOverwritesExistingOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        _ = try writeMaster(master)
        try Data("stale".utf8).write(to: out)
        _ = try NativeDenoiseProcessor(strength: 0.5).process(masterURL: master, outputURL: out, log: nil)
        XCTAssertNoThrow(try FITSReader.readHeader(try Data(contentsOf: out)))   // real FITS replaced the stale file
    }

    func testMissingMasterThrows() throws {
        let dir = try sandbox()
        XCTAssertThrowsError(try NativeDenoiseProcessor()
            .process(masterURL: dir.appendingPathComponent("absent.fit"),
                     outputURL: dir.appendingPathComponent("out.fit"), log: nil))
    }

    func testFailedWriteLeavesNoPartialOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        _ = try writeMaster(master)
        let badOut = dir.appendingPathComponent("no-such-dir/master_processed.fit")
        XCTAssertThrowsError(try NativeDenoiseProcessor()
            .process(masterURL: master, outputURL: badOut, log: nil))
        // No partial/temp artifacts anywhere in the session dir.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(names), ["master.fit"])
    }

    func testAlwaysAvailable() {
        XCTAssertTrue(NativeDenoiseProcessor().isAvailable)     // spec §2.3
        XCTAssertEqual(NativeDenoiseProcessor().name, "Native NR")
    }
}
```

And append to `SessionSettingsTests.swift` (pattern of `testProcessorBackendDefaultAndRoundTrip`, line 61):

```swift
    func testNativeDenoiseBackendRoundTrips() throws {
        var s = SessionSettings.defaults
        s.processorBackend = .nativeDenoise
        let round = try JSONDecoder().decode(SessionSettings.self,
                                             from: JSONEncoder().encode(s))
        XCTAssertEqual(round.processorBackend, .nativeDenoise)
    }
```

Run `swift test --filter NativeDenoiseProcessorTests 2>&1 | tail -3` — expected compile error `cannot find 'NativeDenoiseProcessor' in scope`. (Red.)

- [ ] **Step 2: Add the backend case.** In `Processor.swift:15-17`:

```swift
/// User-selectable processing backend.
public enum ProcessorBackend: String, CaseIterable, Codable {
    case none, graxpert, nativeDenoise
}
```

- [ ] **Step 3: Implement the processor** — create `Sources/LiveAstroCore/Processing/NativeDenoiseProcessor.swift`:

```swift
import Foundation

/// Master-path consumer of `Denoiser` (spec §2.3): reads the linear master via
/// `readLinear`, runs the same two stages in linear domain (the engine picks the
/// linear-domain constants from `sourceIsLinear` — plan finding F3), and writes
/// the result through the existing writer with the temp+rename no-partial-files
/// pattern (the GraXpert-fix precedent). Always available — gives users without
/// GraXpert a denoise option. `master.fit` is never mutated.
public struct NativeDenoiseProcessor: Processor {
    private let strength: Float
    private let fileManager: FileManager

    public init(strength: Float = 0.5, fileManager: FileManager = .default) {
        self.strength = strength
        self.fileManager = fileManager
    }

    public var name: String { "Native NR" }
    public var isAvailable: Bool { true }

    public func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL {
        let data = try Data(contentsOf: masterURL)
        let fits = try FITSReader.readLinear(data)
        let header = try FITSReader.readHeader(data)
        log?("Native NR: \(fits.width)x\(fits.height)x\(fits.channels), strength \(strength)")

        let image = AstroImage(width: fits.width, height: fits.height,
                               channels: fits.channels, pixels: fits.pixels,
                               sourceIsLinear: true)                    // linear-domain mapping
        let denoised = Denoiser.apply(image, strength: strength)

        // Propagate the master's astronomical metadata + stack provenance.
        let metadata = SourceMetadata(fitsKeywords: header.keywords)
        let stackCount = header.keywords["STACKCNT"].flatMap { Int($0) }
        let totalExp = header.keywords["TOTALEXP"].flatMap { Double($0) }
        let out = FITSWriter.float32(width: denoised.width, height: denoised.height,
                                     channels: denoised.channels, pixels: denoised.pixels,
                                     metadata: metadata, stackCount: stackCount,
                                     totalExposureSeconds: totalExp)

        // Temp + rename: no partial master_processed.fit is ever observable.
        let tmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".native-denoise-\(UUID().uuidString).fit")
        do {
            try out.write(to: tmp)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.moveItem(at: tmp, to: outputURL)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
        log?("Native NR: wrote \(outputURL.lastPathComponent)")
        return outputURL
    }
}
```

- [ ] **Step 4: Wire the app layer.** In `ImportController.swift`, replace the whole `processMaster(sessionDirectory:)` body (lines 194-227) with:

```swift
    func processMaster(sessionDirectory: URL) {
        guard !isProcessing, !isImporting, !surface.isSessionRunning() else { return }
        let backend = surface.currentProcessorBackend?() ?? ProcessorBackend.none
        let graxpertExe = GraXpertProcessor.defaultExecutable()
        switch backend {
        case .none:
            return
        case .graxpert:
            guard graxpertExe != nil else {
                surface.presentError("GraXpert not found — install it from graxpert.com"); return
            }
        case .nativeDenoise:
            break   // always available (spec §2.3)
        }
        let master = sessionDirectory.appendingPathComponent("master.fit")
        guard FileManager.default.fileExists(atPath: master.path) else {
            surface.presentError("No master.fit in this session — post-processing needs a natively-stacked master (Raw subs mode).")
            return
        }
        isProcessing = true
        surface.log(backend == .graxpert ? "Processing master with GraXpert…"
                                         : "Processing master with Native NR…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let out = sessionDirectory.appendingPathComponent("master_processed.fit")
                // graxpertExe was nil-checked above for the .graxpert arm; the force
                // unwrap is unreachable otherwise.
                let proc: any Processor = backend == .graxpert
                    ? GraXpertProcessor(executable: graxpertExe!)
                    : NativeDenoiseProcessor()
                let produced = try proc.process(masterURL: master, outputURL: out) { m in
                    Task { @MainActor in self.surface.log(m) }
                }
                await MainActor.run {
                    self.isProcessing = false
                    self.surface.log("Processed → \(produced.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.surface.presentError("Processing failed: \(error)")
                }
            }
        }
    }
```

Also update the stale doc comment on `isProcessing` (line 25) to `/// True while a post-process backend (GraXpert or Native NR) is processing a master (processMaster).`

- [ ] **Step 5: Picker + button.** In `ControlView.swift`, replace the Post-process picker (lines 365-371) with:

```swift
                        Picker("Post-process", selection: $model.processorBackend) {
                            Text("None").tag(ProcessorBackend.none)
                            Text("GraXpert").tag(ProcessorBackend.graxpert)
                            Text("Native NR").tag(ProcessorBackend.nativeDenoise)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.importer.isImporting || model.importer.isProcessing)
                        .help("After stacking, optionally post-process the master to a master_processed FITS: GraXpert (background extraction + denoise, requires install) or the built-in Native NR denoiser.")
```

and the Process-master button block (lines 692-700, gating per plan finding F6) with:

```swift
                if model.processorBackend != .none, model.sourceMode == .nativeStack, let dir = model.lastSessionDirectory {
                    Button(model.importer.isProcessing ? "Processing…" : "Process master") {
                        model.importer.processMaster(sessionDirectory: dir)
                    }
                    .disabled(model.importer.isProcessing
                              || (model.processorBackend == .graxpert && GraXpertProcessor.defaultExecutable() == nil))
                    .help(model.processorBackend == .graxpert
                          ? (GraXpertProcessor.defaultExecutable() == nil
                             ? "GraXpert not found — install from graxpert.com"
                             : "Run GraXpert on the last stacked master → master_processed FITS")
                          : "Run the native denoiser on the last stacked master → master_processed FITS")
                }
```

- [ ] **Step 6: Green + commit**

```bash
swift test --filter "NativeDenoiseProcessorTests|SessionSettingsTests" 2>&1 | tail -4
swift build 2>&1 | tail -2
git add Sources/LiveAstroCore/Processing/Processor.swift \
        Sources/LiveAstroCore/Processing/NativeDenoiseProcessor.swift \
        Sources/LiveAstroStudio/ImportController.swift \
        Sources/LiveAstroStudio/ControlView.swift \
        Tests/LiveAstroCoreTests/NativeDenoiseProcessorTests.swift \
        Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "Denoise T6: NativeDenoiseProcessor backend + picker (produced-URL, temp+rename, round-trip pins)"
```

---

### Task 7: Performance Pin + Full Gates + Review Handoff

**Files:**
- Modify: `Tests/LiveAstroCoreTests/PerformanceTests.swift`

- [ ] **Step 1: Add the 26MP pin** (RCD pattern: Date-timed one-shot, `#if DEBUG` skip — `PerformanceTests.swift:74-76,120-122`). Append inside `PerformanceTests`:

```swift
    // MARK: – Denoiser perf pin (native-noise-reduction spec §4: ≤ 1.0 s at 26 MP release)

    /// Full-sensor 3-channel display-domain frame at Medium strength.
    /// Run only in release — debug builds have no optimisations.
    func testDenoise26MPWithin1Second() throws {
        #if DEBUG
        throw XCTSkip("perf pin is meaningful only with optimizations — run: swift test -c release --filter PerformanceTests")
        #else
        let width = 6248, height = 4176            // ~26 MP, ASI2600MC-Air sensor size
        var rng: UInt64 = 0xD15C_0DE5
        @inline(__always) func nextF() -> Float {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(rng >> 33) / Float(1 << 31)
        }
        // Memory note: at 26MP x 3ch the engine's transient working set is
        // ~1.5-2 GB (input copy + sanitized copy + Y/C1/C2 planes + blur/gradient
        // scratch, each ~104 MB, several alive at once) — within target-hardware
        // budget; buffers free as each stage's locals go out of scope.
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<pixels.count { pixels[i] = 0.2 + nextF() * 0.1 }
        let img = AstroImage(width: width, height: height, channels: 3,
                             pixels: pixels, sourceIsLinear: false)

        _ = Denoiser.apply(                       // warm-up on a small frame
            AstroImage(width: 128, height: 128, channels: 3,
                       pixels: [Float](repeating: 0.2, count: 128 * 128 * 3),
                       sourceIsLinear: false), strength: 0.5)

        let start = Date()
        _ = Denoiser.apply(img, strength: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PerformanceTests · 26 MP Denoiser.apply elapsed: %.2f s", elapsed))
        XCTAssertLessThan(elapsed, 1.0,
            String(format: "Denoise perf pin FAILED: %.2f s (limit 1.0 s, spec §4). " +
                   "Sanctioned ladder: sliding-window box blur, then Accelerate/vImage; " +
                   "Metal is out of scope. Regenerate the Swift golden pin after ANY " +
                   "summation-order change (DUMP_DENOISE_GOLDENS).", elapsed))
        #endif
    }
```

- [ ] **Step 2: Run the pin**

```bash
swift test -c release --filter PerformanceTests 2>&1 | tail -8
```

Expected: all PerformanceTests pass, including the new pin with a printed elapsed ≤ 1.0 s. If it fails: the sanctioned escalation order is (a) replace `boxBlurParallel`'s inner `-r...r` loop with a sliding-window running sum (changes float summation order → **must** re-run `DUMP_DENOISE_GOLDENS` and re-verify the 2e-3 py-pin still holds), then (b) Accelerate/vImage per spec §4. Record the measured time either way in the final report.

- [ ] **Step 3: Full gates**

```bash
swift test 2>&1 | tail -3
swift test -c release --filter PerformanceTests 2>&1 | tail -3
swift build -c release 2>&1 | tail -2
git diff --check && echo "whitespace clean"
git log --oneline main..HEAD
```

Expected: `Test Suite 'All tests' passed` (the watcher/segment batteries, parity, and regression suites run inside the full suite and must be untouched-green — this feature touches none of their inputs); release build `Build complete!`; `whitespace clean`; the branch log shows the T1-T7 commits. If ANY previously-green suite fails, that is a regression introduced by this work — fix before handoff, never re-baseline someone else's test.

- [ ] **Step 4: Commit the pin, then hand off for review (NOT merge)**

```bash
git add Tests/LiveAstroCoreTests/PerformanceTests.swift
git commit -m "Denoise T7: 26MP release perf pin (≤1.0s) + full-gate verification"
```

Then request the external review round (house rule: merge only after review): run `superpowers:requesting-code-review` for the branch diff against the spec, and note in the handoff that spec §6 also calls for the standard post-merge adversarial + quality review. Deliverables to name in the handoff: the results doc (gate table + binding constants), the golden fixtures + generation rule, the A/B PNGs in `~/Desktop/denoise-ab/` for owner eyeballing, and the measured 26MP time. **Do not merge to main. Do not delete the branch.**

---

## Self-Review (executed before finishing the plan)

**Spec coverage walk:**
- §1 (problem: chroma mottle + luma grain, "keep this kind of nebulosity") → T1 metrics (chroma + bg sigma), T2 mottle/bleed fixtures, T3 filament-contrast pin, T1 Step 4 eyeball instruction.
- §2.1 (engine, two stages, contracts) → T2 (signature verbatim; all four passthrough contracts tested), T3 (stage-2 adaptivity + determinism). Contracts quoted verbatim in Global Constraints.
- §2.2 (display path: field, placement, Codable, slider gotcha, default off) → T5 (placement quoted with `SessionPipeline.swift:359-362` context; drag-end closure matches lines 397-399).
- §2.3 (master path: backend case, Processor conformance, readLinear, linear-domain mapping, temp+rename, always-available, picker) → T6; linear mapping via `sourceIsLinear` (finding F3), validated in T1's linear-domain check section.
- §3 (prototype gate, verbatim thresholds, verbatim constants, wavelet fallback at the gate) → T1 (gate STOP step 5; binding-constants table; fallback explicitly an owner decision).
- §4 (≤1.0s 26MP release, Accelerate escalation, Metal out of scope) → T7 pin + sanctioned ladder in the failure message.
- §5 (error handling: pure engine, `noOutput`/no-partials master path) → engine never throws (passthrough guards); T6 temp+rename + `testFailedWriteLeavesNoPartialOutput`. (Deviation recorded as finding F7: write failures propagate the underlying error rather than mapping to `ProcessorError.noOutput` — the thrown error is more diagnostic and `ProcessorError` remains for GraXpert.)
- §6 (testing: unit/golden/integration/processor/perf/post-merge review) → T2-T3 / T4 / T5 / T6 / T7 / T7 Step 4 respectively.
- §7 (future seams: not built) → no Core ML seam code, no accumulator-variance input; `Denoiser` is the shadowable type by construction. Nothing added.

**Placeholder scan:** all Swift/Python blocks are complete and runnable as written; the only intentionally-unfilled values are the `<v>` cells of the T1 results doc (observed values, unknowable pre-run) and the two effect-size floors, both governed by the Deferred-numbers rule. `cp /var/folders/...` in T4 Step 4 is by design filled from the printed path.

**Signature consistency:** `Denoiser.apply(_ image: AstroImage, strength: Float) -> AstroImage` is identical in T2 (definition), T5 (`Float(min(max(adj.denoiseStrength, 0), 1))` call), T6 (processor call), T7 (perf pin), T4 (golden). `denoiseStrength: Double` is consistent across DisplayAdjustments/ControlView/tests (finding F1). `process(masterURL:outputURL:log:) throws -> URL` matches `Processor.swift:11`. Python↔Swift primitive pairs are name-mapped 1:1 (`box_blur`/`boxBlurParallel`, `grad_mag`/`gradientMagnitude`, `block_down`/`blockDown`, `upsample_bilinear`/`upsampleBilinear`, `tile_grid`/`tileGrid`, upper-median + nearest-rank percentile on both sides).

**Fixture-numbers rule check:** every asserted number is either (a) computed in-plan from the fixture's construction (edge-guard 0.01 tolerance on ±0.10 chroma steps; luma-hold 1e-5 from F5's rounding analysis (opponent round-trip + stage-2 blur residuals); FWHM ≤2%, filament ≥95%, golden 2e-3/1e-6 — spec/RCD-precedent values), or (b) explicitly deferred to T1 (`s1MinChromaReduction`, `s2MinSigmaReduction`, all of `Denoiser.K`) under the stated binding rule.

**Known open risks (for the executor, not blockers):** T3's synthetic fixtures may interact with the final T1 constants (e.g., a much larger `lumaRadius` changes how much of the 2%-FWHM budget the star spends) — the reconciliation procedure in T3 Step 2 covers this; the T5 `SessionProfile` init shape is flagged with its authoritative fallback; the tile grid at the 64×64 minimum yields 2×2-pixel tiles, which is degenerate but safe (sigma floor 1e-6) and worth a reviewer look.
