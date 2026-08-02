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

Gate (all at strength 0.5, spec §3 as amended 2026-08-02, owner-approved):
  - bg luma sigma and coarse chroma sigma are measured on the flattest 10% of a
    32x32 luma-MAD tile grid (min 20 tiles; per-tile sigma, median across tiles);
  - effective targets: bg >= min(40%, 0.7*bound), chroma >= min(50%, 0.7*bound),
    where bound = the reduction a blur-everything pass (all guard/blend weights
    forced to 1, same radii/passes) attains on those same tiles, computed here;
  - star FWHM delta <= 2% (whole field) and Veil filament contrast preserved
    >= 95% — the unchanged anti-gaming guards.
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
CHROMA_EDGE_GRAD = 0.25            # display domain
CHROMA_EDGE_GRAD_LINEAR = 0.025    # linear domain
CHROMA_BLEND_GAIN = 2.0            # blend amplitude: min(1, gain * s) — see --sweep-gains
LUMA_PASSES = 2
LUMA_RESIDUAL_K = 1.5
LUMA_BLEND_GAIN = 2.0              # blend amplitude: min(1, gain * s) — see --sweep-gains
LUMA_SIGMA_PROTECT_K = 6.0         # gradient-protect threshold = k * tile sigma (domain-free)
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


# ---- gate metrics (spec §3 as amended 2026-08-02) ---------------------------
# Metric-definition constants (spec-fixed by the amendment, NOT sweep values):
FLATTEST_FRACTION = 0.10   # flattest 10% of the tile grid
MIN_FLAT_TILES = 20        # minimum tile count
BOUND_FACTOR = 0.7         # effective target = min(cap, BOUND_FACTOR * bound)
BG_TARGET_CAP = 0.40       # bg luma sigma reduction cap
CHROMA_TARGET_CAP = 0.50   # coarse chroma sigma reduction cap


def sky_mask(y, tiles=TILES):
    """Darkest 30% of tiles by median -> per-pixel mask. Kept ONLY as the
    background/threshold estimator inside star_fwhm_median (whole-field FWHM
    guard, unchanged by the amendment); noise metrics use flattest_tiles."""
    med, _, row_tile, col_tile = tile_grid(y, tiles)
    cut = percentile_nearest(med, 30.0)
    tile_sky = med <= cut
    return tile_sky[row_tile[:, None], col_tile[None, :]]


def mad_sigma(v):
    m = upper_median(v)
    return 1.4826 * upper_median(np.abs(np.asarray(v).ravel() - m))


def flattest_tiles(y, tiles=TILES):
    """Amended spec §3 noise-measurement region: the flattest 10% of the
    tiles x tiles grid ranked by luma MAD-sigma (stable sort; minimum
    MIN_FLAT_TILES tiles). Selection is computed on the BEFORE luma and reused
    for the after and bound images so all three see identical pixels.
    Returns (coords, row_edges, col_edges) on the tile_grid integer edge grid."""
    h, w = y.shape
    _, sig, _, _ = tile_grid(y, tiles)
    n = max(MIN_FLAT_TILES, int(math.floor(tiles * tiles * FLATTEST_FRACTION)))
    order = np.argsort(sig, axis=None, kind="stable")
    coords = [(int(i) // tiles, int(i) % tiles) for i in order[:n]]
    re_ = [ty * h // tiles for ty in range(tiles + 1)]
    ce_ = [tx * w // tiles for tx in range(tiles + 1)]
    return coords, re_, ce_


def flat_bg_sigma(y, coords, re_, ce_):
    """Metric 1 (amended): per-tile full-res luma MAD-sigma on the flattest
    tiles, median across tiles. Per-tile measurement is immune to tile-to-tile
    background level offsets (the failure mode of the old union-mask metric)."""
    return float(np.median([mad_sigma(y[re_[ty]:re_[ty + 1], ce_[tx]:ce_[tx + 1]])
                            for ty, tx in coords]))


def flat_chroma_sigma(c1, c2, coords, re_, ce_, d=8):
    """Metric 2 (amended): coarse-scale (8x block-mean) chroma sigma measured
    per flattest tile (hypot of the two opponent channels), median across tiles."""
    c1d, c2d = block_down(c1, d), block_down(c2, d)
    sh, sw = c1d.shape
    sigs = []
    for ty, tx in coords:
        r0 = min(re_[ty] // d, sh - 1)
        r1 = max(r0 + 1, min(sh, re_[ty + 1] // d))
        x0 = min(ce_[tx] // d, sw - 1)
        x1 = max(x0 + 1, min(sw, ce_[tx + 1] // d))
        s1 = mad_sigma(c1d[r0:r1, x0:x1])
        s2 = mad_sigma(c2d[r0:r1, x0:x1])
        sigs.append(float(np.hypot(s1, s2)))
    return float(np.median(sigs))


def denoise_bound(img, s):
    """Achievability bound (amended spec §3): the same pipeline shape with every
    guard/blend weight forced to 1 — blur everything, no guards, the theoretical
    maximum reduction for this pipeline. Same radii, passes and downsample as
    the real stages; ONLY the weights differ. Returns (y, c1, c2) of the bound
    image for measurement on the flattest tiles."""
    y, c1, c2 = opponent(img)
    h, w = y.shape
    r = chroma_radius(s)
    out = []
    for c in (c1, c2):
        cd = block_down(c, CHROMA_DOWN)
        cb = cd
        for _ in range(CHROMA_PASSES):
            cb = box_blur(cb, r)
        out.append(c + upsample_bilinear(cb - cd, w, h, CHROMA_DOWN))
    b = y
    for _ in range(LUMA_PASSES):
        b = box_blur(b, luma_radius(s))
    return b, out[0], out[1]


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
        coords, re_, ce_ = flattest_tiles(y0)
        bg0 = flat_bg_sigma(y0, coords, re_, ce_)
        ch0 = flat_chroma_sigma(c10, c20, coords, re_, ce_)
        fw0, nstars = star_fwhm_median(y0)
        fc0 = filament_contrast(y0, *fila) if name == "Veil" else float("nan")
        datasets.append((name, img, coords, re_, ce_, bg0, ch0, fw0, nstars, fc0))

    def deltas(name, img, s, coords, re_, ce_, bg0, ch0, fw0, fc0):
        out = denoise(img, s, linear=False)
        y1, c11, c21 = opponent(out)
        bg1 = flat_bg_sigma(y1, coords, re_, ce_)
        ch1 = flat_chroma_sigma(c11, c21, coords, re_, ce_)
        fw1, _ = star_fwhm_median(y1)
        fc1 = filament_contrast(y1, *fila) if name == "Veil" else float("nan")
        d_bg, d_ch = 1 - bg1 / bg0, 1 - ch1 / ch0
        d_fw = abs(fw1 - fw0) / fw0 if fw0 == fw0 else float("nan")
        pres = fc1 / fc0 if fc0 == fc0 and fc0 > 0 else float("nan")
        return out, bg1, ch1, fw1, fc1, d_bg, d_ch, d_fw, pres

    def bounds(img, s, coords, re_, ce_, bg0, ch0):
        # Achievability bound + effective targets (amended spec §3), measured
        # on the SAME flattest tiles as the real metrics.
        yb, c1b, c2b = denoise_bound(img, s)
        b_bg = 1 - flat_bg_sigma(yb, coords, re_, ce_) / bg0
        b_ch = 1 - flat_chroma_sigma(c1b, c2b, coords, re_, ce_) / ch0
        t_bg = min(BG_TARGET_CAP, BOUND_FACTOR * b_bg)
        t_ch = min(CHROMA_TARGET_CAP, BOUND_FACTOR * b_ch)
        return b_bg, b_ch, t_bg, t_ch

    if args.sweep_gains:
        # Coarse blend-gain grid at s=0.5 (T1-BINDING gains): the amplitude
        # min(1, gain*s) is what makes the effective targets reachable at s=0.5.
        # Pick the smallest pair that clears every effective target with margin,
        # set CHROMA_BLEND_GAIN / LUMA_BLEND_GAIN in the constants block, then
        # re-run WITHOUT --sweep-gains: the gate table (and the results doc)
        # records the chosen values alongside the other constants. The bound
        # (and hence the targets) is gain-independent — printed once per dataset.
        saved = (CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN)
        targets = {}
        for name, img, coords, re_, ce_, bg0, ch0, fw0, nstars, fc0 in datasets:
            b_bg, b_ch, t_bg, t_ch = bounds(img, 0.5, coords, re_, ce_, bg0, ch0)
            targets[name] = (t_bg, t_ch)
            print(f"{name} @0.5: bgσ bound {b_bg:+.1%} target {t_bg:+.1%} | "
                  f"chromaσ bound {b_ch:+.1%} target {t_ch:+.1%}")
        print("| dataset | chromaGain | lumaGain | Δbgσ@0.5 | bgσ target | Δchromaσ@0.5 | chromaσ target | ΔFWHM@0.5 | filament preserved |")
        print("|---|---|---|---|---|---|---|---|---|")
        for cg in (1.5, 2.0, 2.5, 3.0):
            for lg in (1.5, 2.0, 2.5, 3.0):
                CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN = cg, lg
                for name, img, coords, re_, ce_, bg0, ch0, fw0, nstars, fc0 in datasets:
                    _, _, _, _, _, d_bg, d_ch, d_fw, pres = deltas(
                        name, img, 0.5, coords, re_, ce_, bg0, ch0, fw0, fc0)
                    t_bg, t_ch = targets[name]
                    print(f"| {name} | {cg} | {lg} | {d_bg:+.1%} | {t_bg:+.1%} "
                          f"| {d_ch:+.1%} | {t_ch:+.1%} "
                          f"| {d_fw:.2%} | {pres:.1%} |")
        CHROMA_BLEND_GAIN, LUMA_BLEND_GAIN = saved
        return

    print("| dataset | strength | bgσ before | bgσ after | Δbgσ | bgσ bound | bgσ target | chromaσ before | chromaσ after | Δchromaσ | chromaσ bound | chromaσ target | FWHM before | FWHM after | ΔFWHM | filament before | after | preserved |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    gate_ok = True
    gate_invalid = False
    for name, img, coords, re_, ce_, bg0, ch0, fw0, nstars, fc0 in datasets:
        save_png(img, ab / f"{name}_before.png")
        for s in (0.25, 0.5, 0.75, 1.0):
            out, bg1, ch1, fw1, fc1, d_bg, d_ch, d_fw, pres = deltas(
                name, img, s, coords, re_, ce_, bg0, ch0, fw0, fc0)
            b_bg, b_ch, t_bg, t_ch = bounds(img, s, coords, re_, ce_, bg0, ch0)
            print(f"| {name} | {s} | {bg0:.5f} | {bg1:.5f} | {d_bg:+.1%} "
                  f"| {b_bg:+.1%} | {t_bg:+.1%} "
                  f"| {ch0:.5f} | {ch1:.5f} | {d_ch:+.1%} "
                  f"| {b_ch:+.1%} | {t_ch:+.1%} "
                  f"| {fw0:.2f} ({nstars}★) | {fw1:.2f} | {d_fw:.2%} "
                  f"| {fc0:.4f} | {fc1:.4f} | {pres:.1%} |")
            save_png(out, ab / f"{name}_after_s{s}.png")
            if s == 0.5:
                # NaN-strict verdict: an unmeasurable metric (or bound) can never
                # count as a pass. Also require a usable star sample (nstars >=
                # 10) and a positive filament baseline (fc0 > 0) before judging.
                gate_metrics = [d_bg, d_ch, d_fw, b_bg, b_ch] + (
                    [pres] if name == "Veil" else [])
                if (any(m != m for m in gate_metrics) or nstars < 10
                        or (name == "Veil" and not fc0 > 0)):
                    print(f"GATE INVALID: metric unmeasurable on {name} "
                          f"(NaN gate metric/bound, nstars={nstars} < 10, or "
                          "filament fc0 <= 0) — fix the measurement (star "
                          "threshold / filament window) before judging PASS/FAIL.")
                    gate_invalid = True
                    gate_ok = False
                else:
                    for label, meas, bnd, tgt, ok in (
                            ("bgσ", d_bg, b_bg, t_bg, d_bg >= t_bg),
                            ("chromaσ", d_ch, b_ch, t_ch, d_ch >= t_ch)):
                        print(f"GATE {name} {label}: measured {meas:+.1%} | "
                              f"bound {bnd:+.1%} | effective target {tgt:+.1%} "
                              f"| {'PASS' if ok else 'FAIL'}")
                        if not ok:
                            gate_ok = False
                    ok_fw = d_fw <= 0.02
                    print(f"GATE {name} FWHM: measured {d_fw:.2%} | limit 2.00% "
                          f"| {'PASS' if ok_fw else 'FAIL'}")
                    if not ok_fw:
                        gate_ok = False
                    if name == "Veil":
                        ok_fc = pres >= 0.95
                        print(f"GATE {name} filament: preserved {pres:.1%} | "
                              f"limit 95.0% | {'PASS' if ok_fc else 'FAIL'}")
                        if not ok_fc:
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
