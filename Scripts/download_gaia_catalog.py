#!/usr/bin/env python3
"""Robust Gaia DR3 bright-star catalog downloader → LASC binary (Sources/.../brightstars.bin).

Fetches G<=8.5 all-sky from ESA Gaia TAP+, with per-chunk fallback to VizieR/CDS (I/355/gaiadr3).
Splits the all-sky query into declination bands so no single request hammers the archive; retries
per chunk; caches each band to Scripts/.gaia_cache/ so re-runs resume; verifies the total.

Gaia DR3 is ESA/DPAC data, CC BY-NC 3.0 IGO — fetched here DIRECTLY from ESA/CDS (never via Siril).
Attribution: see NOTICE.  Requires: pip install astroquery.
Usage: python3 Scripts/download_gaia_catalog.py [mag_limit] [band_deg]
"""
import struct, os, sys, time, csv

# Default G<=11: plate-solving needs enough catalog stars per field to clear the solver's inlier
# floor even in sparse high-galactic-latitude fields. G<=8.5 gave only ~7 in-frame stars on a real
# M63 sub (below the floor); G<=11 gives ~27. Deeper than 11 doesn't help the match (same bright
# stars) but bloats the file. (~2.7M stars whole-sky, ~32MB.)
MAG   = float(sys.argv[1]) if len(sys.argv) > 1 else 11.0
BAND  = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
HERE  = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".gaia_cache")
OUT   = os.path.join(HERE, "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")
os.makedirs(CACHE, exist_ok=True)

def bands():
    d = -90.0
    while d < 90.0:
        yield (d, min(90.0, d + BAND)); d += BAND

def esa_band(lo, hi):
    from astroquery.gaia import Gaia
    q = (f"SELECT ra, dec, phot_g_mean_mag FROM gaiadr3.gaia_source "
         f"WHERE phot_g_mean_mag <= {MAG} AND dec >= {lo} AND dec < {hi} "
         f"AND ra IS NOT NULL AND dec IS NOT NULL AND phot_g_mean_mag IS NOT NULL")
    r = Gaia.launch_job_async(q).get_results()
    return [(float(x["ra"]), float(x["dec"]), float(x["phot_g_mean_mag"])) for x in r]

def vizier_band(lo, hi):
    from astroquery.vizier import Vizier
    v = Vizier(columns=["RA_ICRS", "DE_ICRS", "Gmag"],
               column_filters={"Gmag": f"<{MAG}", "DE_ICRS": f">={lo} & <{hi}"}, row_limit=-1)
    t = v.query_constraints(catalog="I/355/gaiadr3")
    if not t: return []
    return [(float(x["RA_ICRS"]), float(x["DE_ICRS"]), float(x["Gmag"]))
            for x in t[0] if x["RA_ICRS"] is not None and x["DE_ICRS"] is not None and x["Gmag"] is not None]

def fetch_band(lo, hi):
    cache = os.path.join(CACHE, f"band_{lo:+05.1f}.csv")
    if os.path.exists(cache):
        with open(cache) as f: return [(float(a), float(b), float(c)) for a, b, c in csv.reader(f)]
    stars = None
    for src, fn in (("ESA", esa_band), ("VizieR", vizier_band)):
        for attempt in range(3):
            try:
                print(f"  band [{lo:+.0f},{hi:+.0f}) via {src} try {attempt+1}...", flush=True)
                stars = fn(lo, hi); break
            except Exception as e:
                print(f"    {src} failed: {type(e).__name__}: {str(e)[:90]}", flush=True); time.sleep(6)
        if stars is not None: break
    if stars is None:
        raise RuntimeError(f"band [{lo},{hi}) failed on both ESA and VizieR")
    with open(cache, "w", newline="") as f: csv.writer(f).writerows(stars)
    print(f"    -> {len(stars)} stars cached", flush=True)
    return stars

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])
    buf = bytearray(b"LASC"); buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars: buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    allstars, failed = [], []
    for lo, hi in bands():
        try: allstars += fetch_band(lo, hi)
        except Exception as e: print(f"  BAND FAILED: {e}", flush=True); failed.append((lo, hi))
    if failed:
        print(f"FAILED bands: {failed}\nGot {len(allstars)} so far (cached bands resume next run).", flush=True)
        sys.exit(1)
    open(OUT, "wb").write(pack(allstars))
    print(f"OK wrote {len(allstars)} stars -> {OUT} ({os.path.getsize(OUT)} bytes)", flush=True)
