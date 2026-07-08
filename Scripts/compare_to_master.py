#!/usr/bin/env python3
"""
compare_to_master.py — Register a LiveAstro master.fit against a Siril reference master
and report per-channel Pearson correlation over the full registered overlap.

Usage:
    python3 Scripts/compare_to_master.py <liveastro_master.fit> <siril_master.fit>

Both files are loaded as float32 (H, W, 3).  Row orientation is resolved empirically:
astroalign is tried with Siril in its as-stored FITS byte order and with rows flipped;
whichever produces a valid star-field match is used.  The choice sidesteps ambiguity
in ROWORDER conventions between Siril and LiveAstro's FITSWriter.

Registration runs on half-resolution luminance (matching StackEngine's approach).
Per-channel Pearson r is then computed over the full registered Siril frame — the two
masters have different background levels (Siril is background-subtracted, LiveAstro
retains the raw sky pedestal), so the Pearson r across the full frame captures how
well the nebula structure and relative pixel values agree.
"""
import sys
import warnings
import numpy as np
import astroalign as aa
from astropy.io import fits
from scipy.stats import pearsonr

warnings.filterwarnings("ignore")


def load_fits_rgb(path: str) -> np.ndarray:
    """Load a 3-plane FITS file as (H, W, 3) float32 without any row-order flip.

    Row orientation is handled by the caller via the empirical try-both approach.
    """
    with fits.open(path, memmap=False) as hdul:
        data = hdul[0].data.astype(np.float32)
    if data.ndim == 2:
        data = np.stack([data, data, data], axis=0)
    return np.moveaxis(data, 0, -1)   # (3, H, W) → (H, W, 3)


def half_rgb(rgb: np.ndarray) -> np.ndarray:
    """2× downscale via 2×2 superpixel averaging — matches StackEngine's half-res step."""
    h, w = rgb.shape[:2]
    h2, w2 = (h // 2) * 2, (w // 2) * 2
    r = rgb[:h2, :w2, :]
    return (r[0::2, 0::2, :] + r[1::2, 0::2, :]
            + r[0::2, 1::2, :] + r[1::2, 1::2, :]) / 4


def try_register(src_lum: np.ndarray, tgt_lum: np.ndarray,
                 sigma: float = 3.0, max_pts: int = 80):
    """Return (transform, n_pairs) or None on failure."""
    try:
        tf, (sp, _) = aa.find_transform(src_lum, tgt_lum,
                                        detection_sigma=sigma,
                                        max_control_points=max_pts)
        return tf, len(sp)
    except Exception:
        return None


def pearson(a: np.ndarray, b: np.ndarray) -> float:
    fa, fb = a.ravel().astype(float), b.ravel().astype(float)
    if fa.std() < 1e-9 or fb.std() < 1e-9:
        return float("nan")
    r, _ = pearsonr(fa, fb)
    return float(r)


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: compare_to_master.py <liveastro_master.fit> <siril_master.fit>")
        sys.exit(1)

    la_path, siril_path = sys.argv[1], sys.argv[2]
    print(f"LiveAstro master : {la_path}")
    print(f"Siril master     : {siril_path}")

    print("Loading...")
    # LiveAstro master carries ROWORDER=TOP-DOWN and is loaded as-is.
    la = load_fits_rgb(la_path)
    siril_raw = load_fits_rgb(siril_path)
    siril_flip = siril_raw[::-1, :, :].copy()

    print(f"  LiveAstro  (H×W): {la.shape[0]}×{la.shape[1]}  "
          f"range [{la.min():.4f}, {la.max():.4f}]")
    print(f"  Siril      (H×W): {siril_raw.shape[0]}×{siril_raw.shape[1]}  "
          f"range [{siril_raw.min():.4f}, {siril_raw.max():.4f}]")

    la_half = half_rgb(la)
    la_lum = la_half.mean(axis=-1)

    siril_half_raw = half_rgb(siril_raw)
    si_lum_raw = siril_half_raw.mean(axis=-1)
    siril_half_flip = half_rgb(siril_flip)
    si_lum_flip = siril_half_flip.mean(axis=-1)

    print(f"  LA half-lum {la_lum.shape}  |  Siril half-lum {si_lum_raw.shape}")

    # --- Orientation probe ---
    print("\nRegistration (trying both Siril orientations)...")
    res_raw = try_register(la_lum, si_lum_raw)
    res_flip = try_register(la_lum, si_lum_flip)

    if res_raw is None and res_flip is None:
        print("  Both orientations failed — images may not overlap enough.")
        sys.exit(1)

    if res_raw is not None and (res_flip is None or res_raw[1] >= res_flip[1]):
        transform, n_pairs = res_raw
        siril_half = siril_half_raw
        orient = "Siril as-stored"
    else:
        transform, n_pairs = res_flip
        siril_half = siril_half_flip
        orient = "Siril flipped"

    import numpy as _np
    print(f"  OK — {n_pairs} pairs, {orient}")
    print(f"  rotation={_np.degrees(transform.rotation):.3f}°  "
          f"scale={transform.scale:.5f}  "
          f"t=({transform.translation[0]:.1f}, {transform.translation[1]:.1f})")

    # --- Warp LiveAstro channels to Siril frame ---
    print("\nWarping LiveAstro to Siril coordinate frame (half res)...")
    h_tgt, w_tgt = siril_half.shape[:2]
    warped_chs = []
    for c in range(3):
        wc, _ = aa.apply_transform(transform, la_half[..., c],
                                   _np.zeros((h_tgt, w_tgt), dtype=_np.float32))
        warped_chs.append(wc)
    warped = _np.stack(warped_chs, axis=-1)

    h_min = min(h_tgt, warped.shape[0])
    w_min = min(w_tgt, warped.shape[1])
    warped_c = warped[:h_min, :w_min, :]
    siril_c = siril_half[:h_min, :w_min, :]
    print(f"  Registered frame: {h_min}×{w_min} ({h_min*w_min:,} pixels)")

    # --- Per-channel Pearson correlation, full registered frame ---
    # NOTE: Siril's background is near-zero (background-subtracted); LiveAstro retains
    # the raw sky pedestal. Pearson r over the full frame measures structural agreement
    # in both the bright nebula and the relative sky distribution.
    print("\nPer-channel Pearson r (full registered frame):")
    results = {}
    for i, ch in enumerate("RGB"):
        r = pearson(warped_c[..., i], siril_c[..., i])
        results[ch] = r
        print(f"  {ch}: r = {r:.4f}")

    r_str = "  ".join(f"{ch}={results[ch]:.4f}" for ch in "RGB")
    print(f"\nSummary: {r_str}")
    print("Baseline (Python prototype, 16 subs, half-res): R≈0.87  G≈0.94  B≈0.83")
    delta = {ch: results[ch] - b for ch, b in zip("RGB", (0.87, 0.94, 0.83))}
    d_str = "  ".join(f"{ch}={delta[ch]:+.4f}" for ch in "RGB")
    print(f"Delta vs baseline: {d_str}")


if __name__ == "__main__":
    main()
