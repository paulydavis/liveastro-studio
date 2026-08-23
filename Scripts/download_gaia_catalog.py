#!/usr/bin/env python3
"""Robust Gaia DR3 bright-star catalog downloader → LASC binary (Sources/.../brightstars.bin).

Fetches G<=MAG all-sky in a small number of declination BANDS — few, large queries are gentler on the
archives than many small ones (hammering CDS with hundreds of tile queries gets your IP throttled).
ESA Gaia TAP+ (async, built for big result sets) is primary; CDS/VizieR is the fallback. Each band
caches to Scripts/.gaia_cache/ so re-runs resume; the whole thing is packed + verified.

The full Gaia DR3 catalog (VizieR I/355/gaiadr3 / ESA gaiadr3.gaia_source) lives only on the CDS main
server and ESA — the regional VizieR mirrors do NOT replicate it, so there's no mirror to fall back to.
If BOTH sources time out, they've throttled you: stop, wait ~30-60 min for the cool-down, re-run (it
resumes from cached bands). Gaia DR3 is ESA/DPAC, CC BY-NC 3.0 IGO — see NOTICE. Requires astroquery.
Usage: python3 Scripts/download_gaia_catalog.py [mag_limit] [band_deg]
"""
import struct, os, sys, time, csv, signal

class _AttemptTimeout(Exception): pass
def _on_alarm(signum, frame): raise _AttemptTimeout("attempt exceeded cap")
signal.signal(signal.SIGALRM, _on_alarm)
# Per-attempt hard cap. ESA's async service has NO client timeout — a queued/stuck job blocks forever
# (a real band once sat 56 min). Cap each attempt so a slow/hung job is abandoned and retried (a fresh
# job usually dodges the slow queue) instead of hanging the whole run.
ESA_CAP    = 1200   # 20 min per ESA attempt
VIZIER_CAP = 150    # VizieR throttles under load — fail fast so ESA carries the band

# Default G<=11: enough catalog stars per field to clear the solver's inlier floor even in sparse
# high-galactic-latitude fields (G<=8.5 gave only ~7 in-frame stars on a real M63 sub). ~2.7M stars.
MAG   = float(sys.argv[1]) if len(sys.argv) > 1 else 11.0
BAND  = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
HERE  = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".gaia_cache")
OUT   = os.path.join(HERE, "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")
os.makedirs(CACHE, exist_ok=True)
RETRY_BASE = 8.0    # backoff on failure = RETRY_BASE * 2**attempt (8, 16, 32s) — lets a throttle clear

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
    v = Vizier(columns=["RA_ICRS", "DE_ICRS", "Gmag"], row_limit=-1,
               column_filters={"Gmag": f"<{MAG}", "DE_ICRS": f">={lo} & <{hi}"})
    t = v.query_constraints(catalog="I/355/gaiadr3")
    if not t: return []
    return [(float(x["RA_ICRS"]), float(x["DE_ICRS"]), float(x["Gmag"]))
            for x in t[0] if x["RA_ICRS"] is not None and x["DE_ICRS"] is not None and x["Gmag"] is not None]

def fetch_band(lo, hi):
    # Cache key includes MAG so a re-run at a different depth never replays a stale shallower cache.
    cache = os.path.join(CACHE, f"band_{lo:+05.1f}_g{MAG:g}.csv")
    if os.path.exists(cache):
        with open(cache) as f: return [(float(a), float(b), float(c)) for a, b, c in csv.reader(f)]
    stars = None
    # ESA async primary (handles big bands server-side); VizieR fallback. Exponential backoff on
    # failure lets a rate-limit / read-timeout window clear before the next attempt.
    for src, fn, tries, cap in (("ESA", esa_band, 3, ESA_CAP), ("VizieR", vizier_band, 2, VIZIER_CAP)):
        for attempt in range(tries):
            try:
                print(f"  band [{lo:+.0f},{hi:+.0f}) via {src} try {attempt+1} (cap {cap}s)...", flush=True)
                signal.alarm(cap)
                stars = fn(lo, hi)
                signal.alarm(0)
                break
            except Exception as e:
                signal.alarm(0)
                back = RETRY_BASE * (2 ** attempt)
                print(f"    {src} failed: {type(e).__name__}: {str(e)[:70]} — backoff {back:.0f}s", flush=True)
                time.sleep(back)
        if stars is not None: break
    if stars is None:
        raise RuntimeError(f"band [{lo},{hi}) failed on both ESA and VizieR (likely throttled — wait, re-run)")
    with open(cache, "w", newline="") as f: csv.writer(f).writerows(stars)
    print(f"    -> {len(stars)} stars cached", flush=True)
    return stars

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])   # dec-sorted (StarCatalog.stars(nearRA:) uses a dec band)
    buf = bytearray(b"LASC"); buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars: buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    print(f"G<={MAG}: {len(list(bands()))} dec bands of {BAND}°", flush=True)
    allstars, failed = [], []
    for lo, hi in bands():
        try: allstars += fetch_band(lo, hi)
        except Exception as e: print(f"  BAND FAILED: {e}", flush=True); failed.append((lo, hi))
    if failed:
        print(f"FAILED bands: {failed}\nGot {len(allstars)} so far — cached bands resume next run "
              f"(if both sources failed, wait ~30-60 min for the throttle to clear).", flush=True)
        sys.exit(1)
    open(OUT, "wb").write(pack(allstars))
    print(f"OK wrote {len(allstars)} stars -> {OUT} ({os.path.getsize(OUT)} bytes)", flush=True)
