# Star catalog — generate, host, and wire the download-on-demand asset

LiveAstro Studio plate-solves (and orients north-up) against a Gaia DR3 bright-star catalog that is
**downloaded on demand**, not bundled — so the MIT app ships free of the CC BY-NC Gaia data. This doc
is the one-time operator procedure to produce the catalog, host it, and point the app at it.

The app fetches it via `CatalogInstaller` (`Sources/LiveAstroCore/PlateSolve/CatalogInstaller.swift`),
verifies its SHA-256 + that it parses, and caches it in `~/Library/Application Support/LiveAstroStudio/
catalog/brightstars.bin`. Until `CatalogInstaller.remoteURL`/`expectedSHA256` point at a real asset, the
app just shows the "Download star catalog" button and fails cleanly on click.

## 1. Generate the catalog (`.bin`)

Runs on a network that can reach ESA/CDS/VizieR (the dev sandbox is ESA-blocked; VizieR works):
```bash
cd ~/liveastro-studio
export SSL_CERT_FILE="$(python3 -c 'import certifi; print(certifi.where())')"
python3 Scripts/download_gaia_catalog.py            # default depth G<=11
```
- Writes `Sources/LiveAstroCore/Resources/brightstars.bin` (a transient output — this dir is being
  removed from the package; the file is what you upload, not something you commit).
- **Resumable:** each declination band caches to `Scripts/.gaia_cache/band_<lo>_g<mag>.csv`, so a re-run
  skips completed bands. The mag is in the cache key, so switching depth never replays a stale cache.
- **G≤11 is ~2.7M stars (~32 MB).** Dense galactic-plane bands can exceed VizieR's per-query row limit;
  if a band fails on both ESA and VizieR, split the generator into finer dec×RA tiles (ask, or lower
  `band_deg`: `python3 Scripts/download_gaia_catalog.py 11 5`).

Requires `pip install astroquery`. Attribution: Gaia DR3, ESA/DPAC.

## 2. Host it on GitHub Releases

```bash
shasum -a 256 Sources/LiveAstroCore/Resources/brightstars.bin   # note the hash

gh release create catalog-v1 \
  Sources/LiveAstroCore/Resources/brightstars.bin \
  --repo paulydavis/liveastro-studio \
  --title "Star catalog v1 (Gaia DR3 G<=11)" \
  --notes "Gaia DR3 bright-star subset (G<=11) for native plate-solving. ESA/DPAC."
```
GitHub then serves the asset (no auth needed on a public repo, up to 2 GB) at:
```
https://github.com/paulydavis/liveastro-studio/releases/download/catalog-v1/brightstars.bin
```

## 3. Wire the URL + hash into the app

In `CatalogInstaller.swift`:
```swift
public static var remoteURL = URL(string: "https://github.com/paulydavis/liveastro-studio/releases/download/catalog-v1/brightstars.bin")!
public static var expectedSHA256 = "<the shasum -a 256 output>"
```
Rebuild. The "Download star catalog" button now fetches, verifies against the hash, and enables
north-up. To publish a new catalog, upload a new release asset (e.g. `catalog-v2`) and bump both values.
