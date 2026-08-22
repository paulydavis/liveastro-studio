#!/usr/bin/env python3
"""Robust Gaia DR3 bright-star catalog downloader → LASC binary (Sources/.../brightstars.bin).

Fetches G<=MAG all-sky in small dec×RA TILES so no single query is huge (dense galactic-plane strips
otherwise hang/time-out at G<=11). VizieR (I/355/gaiadr3) is primary; ESA Gaia TAP+ is a fallback.
Each tile caches to Scripts/.gaia_cache/ so re-runs resume; the whole thing is packed + verified.

Gaia DR3 is ESA/DPAC data, CC BY-NC 3.0 IGO — fetched DIRECTLY from CDS/ESA. Attribution: see NOTICE.
Requires: pip install astroquery.
Usage: python3 Scripts/download_gaia_catalog.py [mag_limit] [dec_deg] [ra_deg]
"""
import struct, os, sys, time, csv

# Default G<=11: enough catalog stars per field to clear the solver's inlier floor even in sparse
# high-galactic-latitude fields (G<=8.5 gave only ~7 in-frame stars on a real M63 sub). ~2.7M stars.
MAG     = float(sys.argv[1]) if len(sys.argv) > 1 else 11.0
DEC_DEG = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0   # dec tile height
RA_DEG  = float(sys.argv[3]) if len(sys.argv) > 3 else 15.0   # RA tile width (finer → smaller queries)
# VizieR's public server throttles bursts: ~24 rapid queries then it read-times-out. Pace ourselves
# (a short delay per network tile) and back off exponentially on failure so a throttle window clears
# before the next try, instead of hammering it.
REQUEST_DELAY = 1.5    # seconds between network tiles (cache hits don't wait)
RETRY_BASE    = 5.0    # backoff = RETRY_BASE * 2**attempt (5, 10, 20, 40s)
HERE  = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".gaia_cache")
OUT   = os.path.join(HERE, "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")
os.makedirs(CACHE, exist_ok=True)

def tiles():
    d = -90.0
    while d < 90.0:
        dhi = min(90.0, d + DEC_DEG)
        r = 0.0
        while r < 360.0:
            rhi = min(360.0, r + RA_DEG)
            yield (d, dhi, r, rhi)
            r += RA_DEG
        d += DEC_DEG

def vizier_tile(dlo, dhi, rlo, rhi):
    from astroquery.vizier import Vizier
    Vizier.TIMEOUT = 120                      # fail fast when throttled → back off → retry after it clears
    v = Vizier(columns=["RA_ICRS", "DE_ICRS", "Gmag"], row_limit=-1,
               column_filters={"Gmag": f"<{MAG}", "DE_ICRS": f">={dlo} & <{dhi}",
                               "RA_ICRS": f">={rlo} & <{rhi}"})
    t = v.query_constraints(catalog="I/355/gaiadr3")
    if not t: return []
    return [(float(x["RA_ICRS"]), float(x["DE_ICRS"]), float(x["Gmag"]))
            for x in t[0] if x["RA_ICRS"] is not None and x["DE_ICRS"] is not None and x["Gmag"] is not None]

def esa_tile(dlo, dhi, rlo, rhi):
    from astroquery.gaia import Gaia
    q = (f"SELECT ra, dec, phot_g_mean_mag FROM gaiadr3.gaia_source "
         f"WHERE phot_g_mean_mag <= {MAG} AND dec >= {dlo} AND dec < {dhi} "
         f"AND ra >= {rlo} AND ra < {rhi} "
         f"AND ra IS NOT NULL AND dec IS NOT NULL AND phot_g_mean_mag IS NOT NULL")
    r = Gaia.launch_job_async(q).get_results()
    return [(float(x["ra"]), float(x["dec"]), float(x["phot_g_mean_mag"])) for x in r]

def fetch_tile(dlo, dhi, rlo, rhi):
    # Cache key includes MAG so a re-run at a different depth never replays a stale shallower cache.
    cache = os.path.join(CACHE, f"tile_d{dlo:+05.1f}_r{rlo:05.1f}_g{MAG:g}.csv")
    if os.path.exists(cache):
        with open(cache) as f: return [(float(a), float(b), float(c)) for a, b, c in csv.reader(f)]
    time.sleep(REQUEST_DELAY)   # pace uncached tiles so VizieR doesn't throttle us
    stars = None
    # VizieR first (ESA TAP has been unreliable — 500s); ESA as a fallback. Exponential backoff on
    # failure lets a rate-limit / read-timeout window clear before the next attempt.
    for src, fn, tries in (("VizieR", vizier_tile, 4), ("ESA", esa_tile, 2)):
        for attempt in range(tries):
            try:
                print(f"  tile d[{dlo:+.0f},{dhi:+.0f}) ra[{rlo:.0f},{rhi:.0f}) via {src} try {attempt+1}...", flush=True)
                stars = fn(dlo, dhi, rlo, rhi); break
            except Exception as e:
                back = RETRY_BASE * (2 ** attempt)
                print(f"    {src} failed: {type(e).__name__}: {str(e)[:80]} — backoff {back:.0f}s", flush=True)
                time.sleep(back)
        if stars is not None: break
    if stars is None:
        raise RuntimeError(f"tile d[{dlo},{dhi}) ra[{rlo},{rhi}) failed on both sources")
    with open(cache, "w", newline="") as f: csv.writer(f).writerows(stars)
    print(f"    -> {len(stars)} stars", flush=True)
    return stars

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])   # dec-sorted (StarCatalog.stars(nearRA:) uses a dec band)
    buf = bytearray(b"LASC"); buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars: buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    all_tiles = list(tiles())
    print(f"G<={MAG}: {len(all_tiles)} tiles ({DEC_DEG}° dec × {RA_DEG}° RA)", flush=True)
    allstars, failed = [], []
    for i, (dlo, dhi, rlo, rhi) in enumerate(all_tiles):
        try:
            allstars += fetch_tile(dlo, dhi, rlo, rhi)
            if (i + 1) % 24 == 0:
                print(f"  ... {i+1}/{len(all_tiles)} tiles, {len(allstars)} stars so far", flush=True)
        except Exception as e:
            print(f"  TILE FAILED: {e}", flush=True); failed.append((dlo, dhi, rlo, rhi))
    if failed:
        print(f"FAILED tiles: {len(failed)} (e.g. {failed[:3]}). Got {len(allstars)} so far — cached "
              f"tiles resume next run; re-run to retry, or pass finer args for the dense ones.", flush=True)
        sys.exit(1)
    open(OUT, "wb").write(pack(allstars))
    print(f"OK wrote {len(allstars)} stars -> {OUT} ({os.path.getsize(OUT)} bytes)", flush=True)
