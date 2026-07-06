#!/usr/bin/env python3
"""Build a LiveAstro session folder from already-acquired subs.

Registers subs (astroalign), incrementally mean-stacks, applies the same
MTF autostretch LiveAstro uses, saves snapshot PNGs + manifest.json.
"""
import json, sys, glob, warnings
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import astroalign as aa
from astropy.io import fits

warnings.filterwarnings("ignore")

SRC = Path.home() / "Documents/lights"
OUT = Path.home() / "Documents/LiveAstro/2026-07-01-ngc6888crescentnebula-acquired"
N_SUBS = 120           # ~40 min of real integration
SNAP_EVERY = 4         # snapshot every 4th accepted sub -> 30 snapshots
SUB_SECONDS = 20.0

def debayer_grbg_superpixel(raw):
    """GRBG 2x2 superpixel debayer -> RGB at half resolution (fast, clean)."""
    g1 = raw[0::2, 0::2]; r = raw[0::2, 1::2]
    b = raw[1::2, 0::2]; g2 = raw[1::2, 1::2]
    h = min(g1.shape[0], r.shape[0], b.shape[0], g2.shape[0])
    w = min(g1.shape[1], r.shape[1], b.shape[1], g2.shape[1])
    rgb = np.stack([r[:h, :w], (g1[:h, :w] + g2[:h, :w]) / 2, b[:h, :w]], axis=-1)
    return rgb.astype(np.float32)

def load_sub(path):
    with fits.open(path, memmap=False) as hdul:
        h = hdul[0].header
        data = hdul[0].data.astype(np.float32)
        bzero, bscale = h.get("BZERO", 0), h.get("BSCALE", 1)
        # astropy already applies bzero/bscale on read for unsigned-int convention
        data = np.clip(data / 65535.0, 0, 1)
        ts = h.get("DATE-OBS")
    # Debayer in STORED row order (flipping first shifts the Bayer phase and swaps R/B),
    # then flip the debayered RGB to display orientation.
    rgb = debayer_grbg_superpixel(data)
    if (h.get("ROWORDER", "BOTTOM-UP")).upper() != "TOP-DOWN":
        rgb = rgb[::-1]
    return rgb, ts

def mtf(x, m):
    x = np.clip(x, 0, 1)
    with np.errstate(divide="ignore", invalid="ignore"):
        y = ((m - 1) * x) / (((2 * m - 1) * x) - m)
    return np.clip(np.nan_to_num(y), 0, 1)

def neutralize_background(img):
    """Multiplicative white balance: scale channels so backgrounds (medians) match G.
    Raw OSC sensors are G-dominant; Siril does the equivalent during processing."""
    med = [float(np.median(img[..., c])) for c in range(3)]
    out = img.copy()
    for c in (0, 2):
        if med[c] > 1e-6:
            out[..., c] *= med[1] / med[c]
    return np.clip(out, 0, 1)

def autostretch(img, target=0.25, clip=-2.8):
    img = neutralize_background(img)
    lum = img.mean(axis=-1)
    med = float(np.median(lum))
    madn = 1.4826 * float(np.median(np.abs(lum - med)))
    shadow = min(max(med + clip * madn, 0.0), 1.0)
    denom = max(1 - shadow, 1e-9)
    r = min(max((med - shadow) / denom, 1e-9), 1.0)
    m = ((0.25 - 1) * r) / (((2 * 0.25 - 1) * r) - 0.25)
    return mtf((img - shadow) / denom, m)

def save_png(img, path):
    from PIL import Image
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(path)

def main():
    subs = sorted(glob.glob(str(SRC / "*.fit")))[:N_SUBS]
    if not subs:
        sys.exit("no subs found")
    (OUT / "snapshots").mkdir(parents=True, exist_ok=True)

    ref_rgb, first_ts = load_sub(subs[0])
    ref_lum = ref_rgb.mean(axis=-1)
    acc = ref_rgb.copy()
    count = 1
    snapshots = []

    def record(idx, ts):
        stack = acc / count
        stretched = autostretch(stack)
        name = f"snapshots/{len(snapshots)+1:04d}.png"
        save_png(stretched, OUT / name)
        lum = stack.mean(axis=-1)
        snapshots.append({
            "index": len(snapshots) + 1,
            "timestamp": (ts or first_ts) + ("Z" if not (ts or first_ts).endswith("Z") else ""),
            "source_file": "already-acquired",
            "snapshot_file": name,
            "estimated_integration_seconds": count * SUB_SECONDS,
            "width": int(stack.shape[1]), "height": int(stack.shape[0]),
            "mean": float(lum.mean()), "median": float(np.median(lum)),
            "stddev": float(lum.std()),
        })
        print(f"snapshot {len(snapshots)} @ {count} subs", flush=True)

    record(1, first_ts)
    last_ts = first_ts
    for i, p in enumerate(subs[1:], start=2):
        try:
            rgb, ts = load_sub(p)
            lum = rgb.mean(axis=-1)
            registered, _ = aa.register(lum, ref_lum, detection_sigma=8, max_control_points=40)
            tf, _ = aa.find_transform(lum, ref_lum, detection_sigma=8, max_control_points=40)
            reg_rgb = np.stack([aa.apply_transform(tf, rgb[..., c], ref_lum)[0] for c in range(3)], axis=-1)
            acc += reg_rgb
            count += 1
            last_ts = ts or last_ts
            if count % SNAP_EVERY == 0:
                record(count, ts)
        except Exception as e:
            print(f"skip {Path(p).name}: {e}", flush=True)

    if snapshots[-1]["estimated_integration_seconds"] != count * SUB_SECONDS:
        record(count, last_ts)

    manifest = {
        "session_id": OUT.name,
        "target_name": "NGC 6888 Crescent Nebula",
        "start_time": snapshots[0]["timestamp"],
        "end_time": snapshots[-1]["timestamp"],
        "sub_exposure_seconds": SUB_SECONDS,
        "bortle": 7,
        "location_label": "Round Rock, TX",
        "telescope": "Seestar S30 Pro",
        "camera": "Seestar S30 Pro",
        "mount": "Seestar alt-az",
        "filter": "LP",
        "notes": "Rebuilt from already-acquired subs (registered incremental mean).",
        "snapshots": snapshots,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    print(f"done: {len(snapshots)} snapshots, {count} subs stacked -> {OUT}")

if __name__ == "__main__":
    main()
