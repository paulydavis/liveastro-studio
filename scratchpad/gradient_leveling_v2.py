#!/usr/bin/env python3
"""
Rework R1 gate prototype: validate fit-on-warped gradient leveling.

Core hypothesis under test
--------------------------
LiveAstro's per-sub gradient leveling fits each sub's low-order background plane,
then subtracts (sub_surface - ref_surface). The REAL pipeline warps each sub to
reference alignment (registration). An adversarial review proved that fitting the
plane on the UN-warped (captured) frame, but applying the correction to the WARPED
frame, injects a spurious gradient ~ |gradient| * rotation and distorts a moving
nebula. The proposed fix fits the plane on the WARPED, reference-aligned frame,
mask-excluding the warp border.

This prototype simulates the real pipeline (capture under similarity transform ->
warp back to reference alignment, carrying a coverage mask) and quantifies injected
error for:
    1. fit-PRE-warp  (current/buggy): fit plane on captured frame.
    2. fit-POST-warp (proposed fix):  fit plane on warped frame, mask-aware.
Reference model is fit on the un-warped reference frame in BOTH strategies.

Rigor points:
  - BILINEAR warp resampling (NN double-warp artifacts swamp the signal).
  - Error measured on the SMOOTH background over the covered, star-free region
    (mean + 95th-percentile abs error), not raw max.
  - sigma-clipped tile plane fit (kappa=2, 3 iters) matching Swift BackgroundExtraction.
"""

import numpy as np

np.random.seed(1234)

# ---------------------------------------------------------------------------
# Image geometry
# ---------------------------------------------------------------------------
H, W = 512, 512
YY, XX = np.mgrid[0:H, 0:W].astype(np.float64)
# Normalized coords in [-1, 1] centered on frame; used for smooth models & plane fit.
CX = (W - 1) / 2.0
CY = (H - 1) / 2.0
NX = (XX - CX) / CX
NY = (YY - CY) / CY


# ---------------------------------------------------------------------------
# Smooth background models (the "truth" we measure error against)
# ---------------------------------------------------------------------------
def gradient_field(gx, gy, offset=1000.0):
    """Linear gradient. gx, gy in ADU across half-frame (normalized unit)."""
    return offset + gx * NX + gy * NY


def nebula_field(amp=800.0, offset=1000.0, cx=0.0, cy=0.0, sx=0.9, sy=1.1):
    """Broad smooth 'nebula': a wide 2D gaussian filling ~70% of frame."""
    return offset + amp * np.exp(-(((NX - cx) ** 2) / (2 * sx**2)
                                   + ((NY - cy) ** 2) / (2 * sy**2)))


def add_stars(field, n=400, flux=(3000.0, 40000.0), seed=None):
    """Add point-ish stars (small gaussians) to a smooth field. Returns (image, starmask)."""
    rng = np.random.default_rng(seed)
    img = field.copy()
    starmask = np.zeros((H, W), dtype=bool)
    xs = rng.integers(6, W - 6, size=n)
    ys = rng.integers(6, H - 6, size=n)
    fs = rng.uniform(flux[0], flux[1], size=n)
    for x, y, f in zip(xs, ys, fs):
        sig = rng.uniform(0.9, 1.8)
        y0, y1 = y - 5, y + 6
        x0, x1 = x - 5, x + 6
        yy, xx = np.mgrid[y0:y1, x0:x1]
        g = f * np.exp(-(((xx - x) ** 2 + (yy - y) ** 2) / (2 * sig**2)))
        img[y0:y1, x0:x1] += g
        starmask[y0:y1, x0:x1] |= g > 0.05 * f
    return img, starmask


# ---------------------------------------------------------------------------
# Warp (similarity transform) with BILINEAR resampling + coverage mask
# ---------------------------------------------------------------------------
def _similarity_inverse_map(theta_deg, tx, ty, dst_shape):
    """
    For an output (dst) grid, return source (src) coordinates under the INVERSE of
    a similarity transform S(theta, t) about the frame center. Sampling src at these
    coords warps a src image so its content is transformed by S.
    """
    Hd, Wd = dst_shape
    yy, xx = np.mgrid[0:Hd, 0:Wd].astype(np.float64)
    th = np.deg2rad(theta_deg)
    c, s = np.cos(th), np.sin(th)
    # forward S: p' = R (p - center) + center + t  ; inverse: p = R^-1 (p' - t - center) + center
    dx = xx - CX - tx
    dy = yy - CY - ty
    sx = c * dx + s * dy + CX
    sy = -s * dx + c * dy + CY
    return sx, sy


def bilinear_sample(src, sx, sy):
    """
    Bilinear sample src at fractional coords (sx, sy). Out-of-bounds -> value 0,
    covered=False. Returns (sampled, covered_mask).
    """
    Hs, Ws = src.shape
    x0 = np.floor(sx).astype(np.int64)
    y0 = np.floor(sy).astype(np.int64)
    x1 = x0 + 1
    y1 = y0 + 1
    wx = sx - x0
    wy = sy - y0

    valid = (x0 >= 0) & (y0 >= 0) & (x1 <= Ws - 1) & (y1 <= Hs - 1)

    x0c = np.clip(x0, 0, Ws - 1)
    x1c = np.clip(x1, 0, Ws - 1)
    y0c = np.clip(y0, 0, Hs - 1)
    y1c = np.clip(y1, 0, Hs - 1)

    Ia = src[y0c, x0c]
    Ib = src[y0c, x1c]
    Ic = src[y1c, x0c]
    Id = src[y1c, x1c]

    top = Ia * (1 - wx) + Ib * wx
    bot = Ic * (1 - wx) + Id * wx
    out = top * (1 - wy) + bot * wy
    out = np.where(valid, out, 0.0)
    return out, valid


def capture_and_warp_back(sky_image, theta_deg, tx, ty):
    """
    Simulate the real pipeline:
      1. CAPTURE: the sensor sees the sky under similarity S(theta, t)
         (captured = S applied to the reference-frame sky).
      2. WARP BACK: registration undoes S, mapping captured -> reference alignment.
    Returns (warped_back_image, coverage_mask). Both use BILINEAR resampling.
    """
    # 1. Capture: sample sky at inverse of S -> captured frame content is S(sky).
    sx, sy = _similarity_inverse_map(theta_deg, tx, ty, (H, W))
    captured, cov_cap = bilinear_sample(sky_image, sx, sy)

    # 2. Warp back: apply inverse similarity S^-1 to captured to realign to reference.
    #    Inverse of S(theta, t) is S(-theta, t') -- easiest: compute the src map that
    #    undoes the capture, i.e. sample captured at forward-S coords.
    #    Use the inverse-map helper with the inverse transform parameters.
    th = np.deg2rad(theta_deg)
    c, s = np.cos(th), np.sin(th)
    # inverse translation in the rotated frame
    itx = -(c * tx - s * ty)
    ity = -(s * tx + c * ty)
    sx2, sy2 = _similarity_inverse_map(-theta_deg, itx, ity, (H, W))
    warped, cov_warp = bilinear_sample(captured, sx2, sy2)

    # Coverage of warped-back frame: where the warp-back sample was in-bounds AND
    # the underlying captured pixel was itself covered (double-warp border).
    cov_cap_f, _ = bilinear_sample(cov_cap.astype(np.float64), sx2, sy2)
    coverage = cov_warp & (cov_cap_f > 0.999)
    return warped, coverage


# ---------------------------------------------------------------------------
# sigma-clipped low-order plane / poly fit over tiles (matches BackgroundExtraction)
# ---------------------------------------------------------------------------
def _design_matrix(nx, ny, degree):
    cols = [np.ones_like(nx), nx, ny]
    if degree >= 2:
        cols += [nx * nx, nx * ny, ny * ny]
    return np.stack(cols, axis=-1)


def fit_background(image, degree=1, mask=None, coverage=None,
                   tiles=32, kappa=2.0, iters=3, min_cov_frac=0.75):
    """
    Faithful port of Swift BackgroundExtraction.fitBackground:
      - divide the frame into `tiles`x`tiles` tiles; the tile sample is the MEDIAN
        of ALL pixels in the tile (Swift: vals.sort(); vals[vals.count/2]).
      - sigma-clip HIGH SIDE ONLY (Swift rejects sv[i] > med + kappa*madn), 3 iters,
        MAD-normalized sigma. This is what drops star-dominated (bright) tiles.
        NOTE: because clipping is high-side only, LOW outliers (e.g. warp-border
        tiles whose median is ~0) are NEVER rejected — they corrupt the fit unless
        excluded up front. That is exactly what mask-aware exclusion handles.
      - mask-aware (coverage != None): skip tiles whose covered fraction < min_cov_frac.

    mask: optional bool array of KNOWN-star pixels to exclude from the tile median
          (a diagnostic aid; the real fix is the coverage gate). Faithful Swift has
          no per-pixel mask, so we do NOT pass one in the main experiment.
    coverage: optional bool valid-pixel array; enables the mask-aware tile gate.
    """
    th = np.linspace(0, H, tiles + 1).astype(int)
    tw = np.linspace(0, W, tiles + 1).astype(int)

    tvals, tnx, tny = [], [], []
    for i in range(tiles):
        for j in range(tiles):
            ys, ye = th[i], th[i + 1]
            xs, xe = tw[j], tw[j + 1]
            if ye <= ys or xe <= xs:
                continue
            block = image[ys:ye, xs:xe]
            bnx = NX[ys:ye, xs:xe]
            bny = NY[ys:ye, xs:xe]

            if coverage is not None:
                cov_block = coverage[ys:ye, xs:xe]
                if cov_block.mean() < min_cov_frac:
                    continue  # mask-aware: drop low-coverage border tiles entirely

            # Swift tile statistic = median over ALL pixels in the tile (incl. any
            # border zeros when NOT mask-aware). Optional star mask for diagnostics.
            if mask is not None:
                sel = ~mask[ys:ye, xs:xe]
                if sel.sum() < 8:
                    continue
                tvals.append(np.median(block[sel]))
            else:
                tvals.append(np.median(block))
            # tile center in normalized coords (Swift uses tile center, not mean)
            tnx.append(NX[(ys + ye) // 2, (xs + xe) // 2])
            tny.append(NY[(ys + ye) // 2, (xs + xe) // 2])

    tvals = np.asarray(tvals)
    tnx = np.asarray(tnx)
    tny = np.asarray(tny)

    n_coeff = 3 if degree == 1 else 6
    if tvals.size < n_coeff:
        return None

    # Swift high-side-only MAD sigma-clip over TILE VALUES (independent of the fit).
    keep = np.ones(tvals.shape, dtype=bool)
    for _ in range(iters):
        kept = tvals[keep]
        if kept.size <= n_coeff:
            break
        med = np.median(kept)
        madn = 1.4826 * np.median(np.abs(kept - med))
        if madn <= 1e-12:
            break
        hi_cut = med + kappa * madn
        newkeep = keep & (tvals <= hi_cut)
        if newkeep.sum() == keep.sum():
            break
        keep = newkeep

    if keep.sum() < n_coeff:
        return None
    A = _design_matrix(tnx[keep], tny[keep], degree)
    coeff, *_ = np.linalg.lstsq(A, tvals[keep], rcond=None)
    return coeff


def eval_surface(coeff, degree):
    A = _design_matrix(NX, NY, degree)
    return (A @ coeff).reshape(H, W)


# ---------------------------------------------------------------------------
# Error metric: injected error on SMOOTH background over covered star-free region
# ---------------------------------------------------------------------------
def injected_error(leveled_smooth, truth_smooth, region):
    """
    leveled_smooth: the SMOOTH-background component after leveling (no stars).
    truth_smooth:   what the smooth background SHOULD be after leveling.
    region: bool mask of pixels to evaluate (covered AND star-free AND interior).
    Returns (mean_abs, p95_abs).
    """
    err = np.abs(leveled_smooth[region] - truth_smooth[region])
    return err.mean(), np.percentile(err, 95)


# ---------------------------------------------------------------------------
# Core experiment for one case
# ---------------------------------------------------------------------------
def run_case(sky_smooth_ref, sky_smooth_sub, theta, tx, ty, degree,
             truth_leveled_smooth, star_seed_ref=10, star_seed_sub=20,
             use_mask_aware=True):
    """
    sky_smooth_ref/sub: smooth reference-frame sky (background truth) for ref and sub.
    The sub sky is what the sub *would* show once realigned to reference coords
    (i.e. same reference coordinate system).
    Captures the sub under S(theta, t), warps back, then levels via both strategies.
    truth_leveled_smooth: the correct smooth background after leveling (target).
    Returns dict of metrics.
    """
    # --- Reference frame (un-warped, reference coords). Swift-faithful fit:
    #     tile medians + high-side sigma-clip drop star tiles (no per-pixel mask). ---
    ref_img, ref_stars = add_stars(sky_smooth_ref, seed=star_seed_ref)
    ref_coeff = fit_background(ref_img, degree=degree)

    # --- Sub: build full sky (smooth + stars) in reference coords, then capture+warp ---
    sub_sky_full, sub_starmask_ref = add_stars(sky_smooth_sub, seed=star_seed_sub)

    # PRE-warp fit (BUGGY): fit the sub plane on the CAPTURED (un-warped, S-rotated)
    # frame, mask-aware on the captured frame's own border coverage. The resulting
    # coeffs are in CAPTURED coords but get applied on the reference grid -> the bug.
    sx, sy = _similarity_inverse_map(theta, tx, ty, (H, W))
    captured_full, cov_cap = bilinear_sample(sub_sky_full, sx, sy)
    pre_coeff = fit_background(captured_full, degree=degree, coverage=cov_cap)

    # Warp back (bilinear) full sub, smooth-only component, and star mask + coverage.
    warped_full, coverage = capture_and_warp_back(sub_sky_full, theta, tx, ty)
    warped_smooth, _ = capture_and_warp_back(sky_smooth_sub, theta, tx, ty)
    warped_starmask_f, _ = capture_and_warp_back(sub_starmask_ref.astype(float), theta, tx, ty)
    warped_starmask = warped_starmask_f > 0.5

    # POST-warp fit (FIX): fit the sub plane on the WARPED (reference-aligned) frame,
    # mask-aware (skip tiles with covered fraction < 0.5). No per-pixel star mask —
    # high-side sigma-clip drops star tiles, matching Swift.
    cov_arg = coverage if use_mask_aware else None
    post_coeff = fit_background(warped_full, degree=degree, coverage=cov_arg)

    ref_surf = eval_surface(ref_coeff, degree)
    pre_surf = eval_surface(pre_coeff, degree)   # in reference coords (fit was in captured coords)
    post_surf = eval_surface(post_coeff, degree)

    # Leveling applies (sub_surface - ref_surface) subtracted from warped frame.
    # We evaluate on the SMOOTH warped background component.
    baseline_smooth = warped_smooth                                   # warp-only, no leveling
    pre_leveled = warped_smooth - (pre_surf - ref_surf)
    post_leveled = warped_smooth - (post_surf - ref_surf)

    # Evaluation region: covered, interior (avoid the 3px warp fringe), star-free.
    interior = np.zeros((H, W), dtype=bool)
    interior[8:H - 8, 8:W - 8] = True
    region = coverage & interior & (~warped_starmask)

    base_m, base_p = injected_error(baseline_smooth, truth_leveled_smooth, region)
    pre_m, pre_p = injected_error(pre_leveled, truth_leveled_smooth, region)
    post_m, post_p = injected_error(post_leveled, truth_leveled_smooth, region)

    return {
        "baseline_mean": base_m, "baseline_p95": base_p,
        "pre_mean": pre_m, "pre_p95": pre_p,
        "post_mean": post_m, "post_p95": post_p,
        "coverage_frac": coverage.mean(),
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def fmt(x):
    return f"{x:9.3f}"


def print_header():
    print(f"{'case':<26}{'baseline':>20}{'fit-PRE-warp':>20}{'fit-POST-warp':>22}")
    print(f"{'':<26}{'mean':>10}{'p95':>10}{'mean':>10}{'p95':>10}{'mean':>11}{'p95':>11}")
    print("-" * 90)


def print_row(name, m):
    print(f"{name:<26}"
          f"{m['baseline_mean']:>10.3f}{m['baseline_p95']:>10.3f}"
          f"{m['pre_mean']:>10.3f}{m['pre_p95']:>10.3f}"
          f"{m['post_mean']:>11.3f}{m['post_p95']:>11.3f}")


def main():
    DEGREE = 2  # degree-2 needed to model a frame-filling nebula (C2); see report
    print("=" * 90)
    print(f"Gradient-leveling v2 gate  (bilinear warp, degree={DEGREE} plane, "
          f"kappa=2 x3, mask-aware tiles)")
    print("=" * 90)

    results = {}

    # ---- C1: common gradient, no-op case. sub sky == ref sky (same gradient). ----
    print("\n[C1] Common gradient, no-op (leveling should be ~0). Sub=ref sky, rotated.")
    print_header()
    g = gradient_field(gx=120.0, gy=-80.0)       # a real sky gradient, common to both
    for theta in (0.1, 1.0, 5.0, 180.0):
        # sub is the SAME sky as ref; correct leveled smooth == warped smooth (no-op).
        warped_smooth_truth, _ = capture_and_warp_back(g, theta, 0.0, 0.0)
        m = run_case(g, g, theta, 0.0, 0.0, DEGREE,
                     truth_leveled_smooth=warped_smooth_truth,
                     star_seed_ref=10, star_seed_sub=10)
        results[f"C1 theta={theta}"] = m
        print_row(f"C1 rot={theta}deg", m)

    # ---- C1b: real differential gradient to remove; small rotation. ----
    print("\n[C1b] Real differential (ref g0, sub g1) + small rotation.")
    print("      Target: sub leveled to REF's gradient (differential removed).")
    print_header()
    g0 = gradient_field(gx=120.0, gy=-80.0)                 # reference gradient
    g1 = gradient_field(gx=60.0, gy=40.0)                   # sub's DIFFERENT gradient
    theta_b = 2.0
    # After correct leveling, sub's smooth background should match ref's gradient g0
    # in the covered region (differential g1-g0 removed). Truth = warp of g0.
    warped_g0_truth, _ = capture_and_warp_back(g0, theta_b, 0.0, 0.0)
    mb = run_case(g0, g1, theta_b, 0.0, 0.0, DEGREE,
                  truth_leveled_smooth=warped_g0_truth,
                  star_seed_ref=10, star_seed_sub=20)
    results["C1b"] = mb
    print_row(f"C1b diff rot={theta_b}deg", mb)

    # ---- C2: frame-filling nebula, sub dithered (translation), warped back. ----
    print("\n[C2] Frame-filling nebula (~70%), sub dithered + slight rotation.")
    print("      Target: leveling difference cancels common nebula (no-op ~0).")
    print_header()
    neb = nebula_field(amp=800.0, offset=1000.0)
    for (th_n, tx_n, ty_n, label) in [
        (0.5, 18.0, -12.0, "dither+rot"),
        (0.1, 25.0, 20.0, "dither"),
    ]:
        warped_neb_truth, _ = capture_and_warp_back(neb, th_n, tx_n, ty_n)
        m = run_case(neb, neb, th_n, tx_n, ty_n, DEGREE,
                     truth_leveled_smooth=warped_neb_truth,
                     star_seed_ref=30, star_seed_sub=30)
        results[f"C2 {label}"] = m
        print_row(f"C2 {label}", m)

    # ---- Mask-aware necessity: C1 at 5deg WITHOUT mask-aware tile exclusion. ----
    print("\n[MASK] Post-warp fit WITHOUT mask-aware tile exclusion (border zeros).")
    print_header()
    theta_m = 5.0
    warped_smooth_truth, _ = capture_and_warp_back(g, theta_m, 0.0, 0.0)
    m_no = run_case(g, g, theta_m, 0.0, 0.0, DEGREE,
                    truth_leveled_smooth=warped_smooth_truth,
                    star_seed_ref=10, star_seed_sub=10, use_mask_aware=False)
    m_yes = results["C1 theta=5.0"]
    print_row("C1 rot=5 NO mask-aware", m_no)
    print_row("C1 rot=5 mask-aware", m_yes)

    # ---- Verdicts ----
    print("\n" + "=" * 90)
    print("VERDICTS")
    print("=" * 90)

    # NOISE_FLOOR: injected error below this (ADU, on a ~1000 ADU background = ~0.1%)
    # is negligible — driven by tile-median discretization + degree-2 fit variance,
    # not the warp bug. In that regime "post ~ pre" is a legitimate no-op tie.
    NOISE_FLOOR = 2.0

    def verdict(name, m, tol_ratio=0.5):
        # PASS if EITHER post is clearly below pre (the bug regime), OR both are
        # already at/below the noise floor (nothing to fix — legitimate no-op).
        clearly_better = (m["post_mean"] < m["pre_mean"] * tol_ratio and
                          m["post_p95"] < m["pre_p95"] * tol_ratio)
        both_negligible = (m["post_mean"] <= NOISE_FLOOR and
                           m["pre_mean"] <= NOISE_FLOOR)
        ok = clearly_better or both_negligible
        tag = "PASS" if ok else "FAIL"
        if both_negligible and not clearly_better:
            tag = "PASS (both < noise floor; no bug to fix)"
        print(f"  {name:<22} pre(mean/p95)={m['pre_mean']:7.3f}/{m['pre_p95']:7.3f}  "
              f"post={m['post_mean']:7.3f}/{m['post_p95']:7.3f}  -> {tag}")
        return ok

    c1_pass = all(verdict(f"C1 rot={t}", results[f"C1 theta={t}"])
                  for t in (0.1, 1.0, 5.0, 180.0))
    # C1b: post-warp must reduce the differential (lower error than pre-warp).
    c1b_pass = (mb["post_mean"] < mb["pre_mean"] and mb["post_p95"] < mb["pre_p95"])
    print(f"  {'C1b differential':<22} pre={mb['pre_mean']:7.3f}/{mb['pre_p95']:7.3f}  "
          f"post={mb['post_mean']:7.3f}/{mb['post_p95']:7.3f}  "
          f"-> {'PASS (post reduces differential)' if c1b_pass else 'FAIL'}")
    c2_pass = all(verdict(f"C2 {lbl}", results[f"C2 {lbl}"])
                  for lbl in ("dither+rot", "dither"))

    # Mask-aware necessity: without it, post-warp should be clearly worse.
    mask_needed = (m_no["post_mean"] > m_yes["post_mean"] * 2.0 or
                   m_no["post_p95"] > m_yes["post_p95"] * 2.0)
    print(f"  {'mask-aware needed':<22} no-mask post={m_no['post_mean']:7.3f}/{m_no['post_p95']:7.3f}  "
          f"mask post={m_yes['post_mean']:7.3f}/{m_yes['post_p95']:7.3f}  "
          f"-> {'YES (needed)' if mask_needed else 'NO'}")

    gate = c1_pass and c1b_pass and c2_pass and mask_needed
    print("\n" + "=" * 90)
    print(f"GATE: {'PASS' if gate else 'BLOCKED'}   "
          f"(C1={c1_pass}, C1b={c1b_pass}, C2={c2_pass}, mask-aware-needed={mask_needed})")
    print("=" * 90)
    return gate


if __name__ == "__main__":
    ok = main()
    raise SystemExit(0 if ok else 1)
