# Star catalog — build, host, and wire the download-on-demand asset

LiveAstro Studio plate-solves (and orients north-up) against a bright-star catalog that is
**downloaded on demand**, not bundled — so the MIT app ships without a 30 MB data blob.

The app fetches it via `CatalogInstaller` (`Sources/LiveAstroCore/PlateSolve/CatalogInstaller.swift`),
verifies its SHA-256 (**required** — an empty `expectedSHA256` fails closed rather than installing an
unverified file) and that it parses, and caches it in `~/Library/Application Support/LiveAstroStudio/
catalog/brightstars.bin`.

## Current catalog: Tycho-2 (shipped)

**Tycho-2** (CDS I/259; Høg et al. 2000) — ~2.5M stars complete to V≈11.5, all-sky, ICRS. The classic
astrometric / plate-solving catalog, **freely redistributable** (ESA Hipparcos mission). Served as 20
static `.gz` files from the CDS archive (`cdsarc`), which is **separate infrastructure from the
throttled TAP/query engine** — so it downloads fast and reliably.

```bash
cd ~/liveastro-studio
export SSL_CERT_FILE="$(python3 -c 'import certifi; print(certifi.where())')"
python3 Scripts/build_tycho2_catalog.py     # → Sources/LiveAstroCore/Resources/brightstars.bin (~30 MB)
```
- Downloads the 20 `tyc2.dat.NN.gz` files to `Scripts/.tycho2_cache/` (skip-existing → resumable),
  parses mean RA/Dec + VT (fallback BT) mag, writes the dec-sorted LASC binary.
- The output `Sources/LiveAstroCore/Resources/brightstars.bin` is a **transient artifact** — it's what
  you upload, not something you commit (the `Resources` dir was removed from the package).

### As shipped (catalog-v1)
- 2,539,913 stars, 30,478,968 bytes.
- SHA-256 `360c949de295d09a1c849e76d353ab667be6afddac814f94a72e4177a9610d22`.
- Hosted: https://github.com/paulydavis/liveastro-studio/releases/download/catalog-v1/brightstars.bin
- Wired into `CatalogInstaller.remoteURL` + `expectedSHA256`.

## Alternative: Gaia DR3 (deeper, but painful to fetch)

`Scripts/download_gaia_catalog.py` builds a G≤11 Gaia DR3 subset (~2.7M) via ESA/VizieR TAP. It works
but the query services throttle/queue heavily (dense bands ran ~1 hr each; regional VizieR mirrors
don't replicate Gaia DR3). Kept for reference; **Tycho-2 is the shipped choice** — comparable density
for plate-solving, faster/reliable to obtain, and unrestricted. Note Gaia DR3 is CC BY-NC 3.0 IGO
(download-on-demand only, never bundle).

## Publish a new catalog

1. Build the `.bin` (above), then `shasum -a 256 Sources/LiveAstroCore/Resources/brightstars.bin`.
2. `gh release create catalog-vN <bin> --repo paulydavis/liveastro-studio --title "..." --notes "..."`
3. Set `CatalogInstaller.remoteURL` (…/catalog-vN/brightstars.bin) + `expectedSHA256` to the new hash; rebuild.
