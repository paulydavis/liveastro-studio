#!/usr/bin/env python3
"""Generate brightstars.bin: Gaia DR3 (the catalog Siril uses) filtered to G<=8.5, all-sky,
packed into the LASC binary format {magic "LASC", u32 version=1, u32 count, then count×
{ra,dec,mag} float32 LE}, records sorted by ascending dec.
Requires: pip install astroquery   (astropy is already present)
Run: python3 Scripts/generate_star_catalog.py  ->  Sources/LiveAstroCore/Resources/brightstars.bin

Attribution (Gaia DR3 ships in the product — required acknowledgement):
  This work has made use of data from the European Space Agency (ESA) mission Gaia
  (https://www.cosmos.esa.int/gaia), processed by the Gaia Data Processing and Analysis
  Consortium (DPAC, https://www.cosmos.esa.int/web/gaia/dpac/consortium).
"""
import struct, os
from astroquery.gaia import Gaia

MAG_LIMIT = 8.5
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "LiveAstroCore", "Resources", "brightstars.bin")

def fetch():
    job = Gaia.launch_job_async(
        f"SELECT ra, dec, phot_g_mean_mag FROM gaiadr3.gaia_source "
        f"WHERE phot_g_mean_mag <= {MAG_LIMIT} AND ra IS NOT NULL AND dec IS NOT NULL "
        f"AND phot_g_mean_mag IS NOT NULL")
    r = job.get_results()
    return [(float(row["ra"]), float(row["dec"]), float(row["phot_g_mean_mag"])) for row in r]

def pack(stars):
    stars = sorted(stars, key=lambda s: s[1])   # ascending dec
    buf = bytearray(b"LASC")
    buf += struct.pack("<II", 1, len(stars))
    for ra, dec, mag in stars:
        buf += struct.pack("<fff", ra, dec, mag)
    return bytes(buf)

if __name__ == "__main__":
    stars = fetch()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(pack(stars))
    print(f"wrote {len(stars)} stars -> {OUT} ({os.path.getsize(OUT)} bytes)")
