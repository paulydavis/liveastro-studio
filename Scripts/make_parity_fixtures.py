#!/usr/bin/env python3
"""Generate parity fixtures for ParityTests.swift.

Picks two NGC 6888 subs ~40 apart (index 0 and 40 in sorted order from
~/Documents/lights), crops the central 1024×1024 region at even pixel offsets
(preserving GRBG Bayer phase), writes two 16-bit FITS fixtures and a JSON file
of expected transform values.

Orientation notes
-----------------
FITSReader.read() flips pixel rows when ROWORDER is absent (defaults BOTTOM-UP).
FolderFrameSource.loadRawFrame() stores the already-flipped (top-down) pixels in
RawFrame.image, but leaves RawFrame.bottomUp = True.  StackEngine's luminance loop
then re-flips via  srcRow = hh - 1 - j  (when bottomUp is True), undoing the first
flip.  Net result for real files with no ROWORDER header: StackEngine luminance is
in STORED (bottom-up) order.

This script therefore builds superpixel luminance WITHOUT any additional row flip,
matching the double-flip → identity that StackEngine applies.  The orientation of
the expected transform coordinates is STORED (bottom-up).
"""

import json
import math
import os
import sys
import warnings
from pathlib import Path

import numpy as np
import astroalign as aa
from astropy.io import fits

warnings.filterwarnings("ignore")

LIGHTS = Path.home() / "Documents/lights"
REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "Tests/LiveAstroCoreTests/Fixtures"
CROP = 1024
IDX_A = 0
IDX_B = 40


def get_subs() -> tuple[Path, Path]:
    files = sorted(f for f in os.listdir(LIGHTS) if f.lower().endswith(".fit"))
    if len(files) < IDX_B + 1:
        sys.exit(f"Need ≥ {IDX_B + 1} subs in {LIGHTS}, found {len(files)}")
    return LIGHTS / files[IDX_A], LIGHTS / files[IDX_B]


def read_normalized(path: Path) -> tuple[np.ndarray, fits.Header]:
    """Return float32 [0,1] array in stored row order plus the FITS header."""
    with fits.open(str(path), memmap=False) as hdul:
        hdr = hdul[0].header
        data = hdul[0].data  # astropy applies BZERO/BSCALE: uint16 values 0-65535
    return data.astype(np.float32) / 65535.0, hdr


def crop_center(data: np.ndarray, size: int) -> tuple[np.ndarray, int, int]:
    """Central crop with even offsets to preserve GRBG Bayer phase."""
    h, w = data.shape
    row_off = (h // 2) - (size // 2)
    col_off = (w // 2) - (size // 2)
    if row_off % 2 != 0:
        row_off += 1
    if col_off % 2 != 0:
        col_off += 1
    assert row_off % 2 == 0 and col_off % 2 == 0, "Odd offset breaks Bayer phase"
    return data[row_off : row_off + size, col_off : col_off + size], row_off, col_off


def write_fixture(path: Path, crop_f32: np.ndarray, hdr: fits.Header) -> int:
    """Write 16-bit FITS (BZERO=32768 unsigned convention), BAYERPAT=GRBG.

    No ROWORDER keyword is written so FITSReader.swift defaults to BOTTOM-UP,
    matching the original source files.
    """
    u16 = np.clip(crop_f32 * 65535.0 + 0.5, 0, 65535).astype(np.uint16)
    hdu = fits.PrimaryHDU(u16)
    h = hdu.header
    # BZERO/BSCALE set automatically by astropy for uint16; make explicit
    h["BZERO"] = 32768
    h["BSCALE"] = 1
    h["BAYERPAT"] = "GRBG"
    date_obs = hdr.get("DATE-OBS")
    if date_obs:
        h["DATE-OBS"] = date_obs
    # Intentionally omit ROWORDER to match source files
    hdu.writeto(str(path), overwrite=True)
    size = path.stat().st_size
    print(f"  wrote {path.name}: {size / 1024 / 1024:.2f} MB")
    return size


def superpixel_lum(data: np.ndarray) -> np.ndarray:
    """4-pixel average superpixel luminance in STORED (bottom-up) order.

    Formula: (G1 + R + B + G2) / 4  — identical to StackEngine's CFA average.
    No row flip applied; see module docstring for why this matches Swift behavior.
    """
    g1 = data[0::2, 0::2]  # GRBG: G at even-row, even-col
    r  = data[0::2, 1::2]  # R  at even-row, odd-col
    b  = data[1::2, 0::2]  # B  at odd-row,  even-col
    g2 = data[1::2, 1::2]  # G  at odd-row,  odd-col
    h = min(g1.shape[0], r.shape[0], b.shape[0], g2.shape[0])
    w = min(g1.shape[1], r.shape[1], b.shape[1], g2.shape[1])
    return (g1[:h, :w] + r[:h, :w] + b[:h, :w] + g2[:h, :w]) / 4.0


def extract_transform(tf) -> tuple[float, float, float, float]:
    """Extract (rotation_deg, scale, tx, ty) from a scikit-image AffineTransform."""
    M = tf.params  # 3×3 homogeneous matrix
    scale = math.sqrt(float(M[0, 0]) ** 2 + float(M[1, 0]) ** 2)
    rotation_rad = math.atan2(float(M[1, 0]), float(M[0, 0]))
    return math.degrees(rotation_rad), scale, float(M[0, 2]), float(M[1, 2])


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    path_a, path_b = get_subs()
    print(f"Sub A (index {IDX_A}): {path_a.name}")
    print(f"Sub B (index {IDX_B}): {path_b.name}")

    data_a, hdr_a = read_normalized(path_a)
    data_b, hdr_b = read_normalized(path_b)

    h0, w0 = data_a.shape
    print(f"Raw shape: {h0}×{w0}")

    crop_a, row_off, col_off = crop_center(data_a, CROP)
    crop_b, _, _ = crop_center(data_b, CROP)
    print(f"Crop offsets: row={row_off} (even={row_off % 2 == 0}), col={col_off} (even={col_off % 2 == 0})")

    size_a = write_fixture(OUT_DIR / "parity_a.fit", crop_a, hdr_a)
    size_b = write_fixture(OUT_DIR / "parity_b.fit", crop_b, hdr_b)

    limit = 3 * 1024 * 1024
    if size_a > limit or size_b > limit:
        sys.exit(f"ERROR: fixture exceeds 3 MB — a={size_a}, b={size_b}")

    # Build superpixel luminance in STORED order (matches StackEngine)
    lum_a = superpixel_lum(crop_a)
    lum_b = superpixel_lum(crop_b)
    print(f"Luminance shape: {lum_a.shape} (STORED/bottom-up orientation)")

    print("Running astroalign.find_transform(A → B)…")
    try:
        tf, (src_pts, dst_pts) = aa.find_transform(
            lum_a, lum_b, detection_sigma=5, max_control_points=50
        )
    except Exception as exc:
        sys.exit(f"astroalign failed: {exc}")

    rotation_deg, scale, tx, ty = extract_transform(tf)
    n_pairs = int(len(src_pts))

    print(f"  rotation:  {rotation_deg:.6f}°")
    print(f"  scale:     {scale:.8f}")
    print(f"  tx:        {tx:.4f} px (half-res)")
    print(f"  ty:        {ty:.4f} px (half-res)")
    print(f"  n_pairs:   {n_pairs}")

    expected = {
        "rotation_deg": rotation_deg,
        "scale": scale,
        "tx": tx,
        "ty": ty,
        "n_source_stars_min": 25,
    }

    json_path = OUT_DIR / "parity_expected.json"
    json_path.write_text(json.dumps(expected, indent=2))
    print(f"  wrote {json_path.name}")
    print("\nOrientation: STORED (bottom-up) — matches StackEngine double-flip for no-ROWORDER files.")


if __name__ == "__main__":
    main()
