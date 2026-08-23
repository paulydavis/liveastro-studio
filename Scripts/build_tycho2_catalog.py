#!/usr/bin/env python3
"""Build the plate-solve star catalog from Tycho-2 (CDS I/259) → LASC binary.

Tycho-2: ~2.5M stars complete to V~11.5, all-sky, ICRS — THE classic astrometric / plate-solving
catalog (astrometry.net was built on it). Served as 20 static .gz files from the CDS archive
(cdsarc), which is SEPARATE infrastructure from the throttled TAP/query engine, so it downloads
fast + reliably (Gaia DR3 via TAP throttled/queued us for ~1hr per band). Tycho-2 is also freely
redistributable (ESA Hipparcos mission — no CC BY-NC restriction, unlike Gaia DR3).

Output = the LASC format StarCatalog expects: magic 'LASC' + u32 version + u32 count, then
count × {ra,dec,mag} float32, dec-sorted. ~2.5M stars, ~30 MB.
Usage: python3 Scripts/build_tycho2_catalog.py
"""
import struct, os, gzip, urllib.request

HERE   = os.path.dirname(os.path.abspath(__file__))
CACHE  = os.path.join(HERE, ".tycho2_cache")
OUT    = os.path.join(HERE, "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")
BASE   = "https://cdsarc.cds.unistra.fr/ftp/I/259/"
NFILES = 20
os.makedirs(CACHE, exist_ok=True)

def fetch(name):
    path = os.path.join(CACHE, name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    tmp = path + ".part"
    print(f"  downloading {name}...", flush=True)
    urllib.request.urlretrieve(BASE + name, tmp)
    os.replace(tmp, path)   # atomic — a killed download never leaves a truncated cache file
    return path

def parse(path):
    """tyc2.dat records are '|'-delimited: [2]=mRAdeg [3]=mDEdeg (mean ICRS pos; blank ~2% → fall
    back to observed [24]/[25]), [17]=BTmag [19]=VTmag. Prefer VT, else BT."""
    out = []
    with gzip.open(path, "rt") as f:
        for line in f:
            fld = line.split("|")
            if len(fld) < 20:
                continue
            ra  = fld[2].strip() or (fld[24].strip() if len(fld) > 24 else "")
            dec = fld[3].strip() or (fld[25].strip() if len(fld) > 25 else "")
            mag = fld[19].strip() or fld[17].strip()
            if not (ra and dec and mag):
                continue
            try:
                out.append((float(ra), float(dec), float(mag)))
            except ValueError:
                continue
    return out

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])   # dec-sorted for StarCatalog's dec-band query
    buf = bytearray(b"LASC"); buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars:
        buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    allstars = []
    for i in range(NFILES):
        name = f"tyc2.dat.{i:02d}.gz"
        allstars += parse(fetch(name))
        print(f"  {name}: cumulative {len(allstars)} stars", flush=True)
    data = pack(allstars)
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"OK wrote {len(allstars)} stars -> {OUT} ({len(data)} bytes)", flush=True)
