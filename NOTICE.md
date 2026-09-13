# Notices and Credits

LiveAstro Studio is licensed under the MIT License (see `LICENSE`). It vendors
no third-party source code and has no runtime dependencies beyond Apple's SDKs.

## Algorithms implemented from published literature

The following algorithms are implemented from their published descriptions
(mathematical methods, which are not themselves copyrightable). No third-party
implementation source was copied or adapted.

- **Demosaicing** — Malvar, H.S., He, L., Cutler, R., "High-Quality Linear
  Interpolation for Demosaicing of Bayer-Patterned Color Images," IEEE ICASSP
  2004. The 5×5 gradient-corrected interpolation filters are transcribed from
  the paper.
- **Auto-stretch** — midtones transfer function (MTF) per the PixInsight
  Screen Transfer Function documentation.
- **Star registration** — triangle-similarity matching (Groth/Valdes lineage)
  with RANSAC + Umeyama least-squares transform estimation, from the standard
  literature.
- **Pixel rejection** — Huber winsorized sigma clipping.

## Star catalog (downloaded at runtime)

Native plate-solving / north-up uses the **Tycho-2 Catalogue** (Høg, E. et al.,
2000, A&A 355, L27), a product of the ESA Hipparcos space astrometry mission.
Tycho-2 is freely available and redistributable. LiveAstro Studio does not bundle
it — the app downloads a pre-built subset on demand (see `docs/CATALOG.md`) and
caches it locally, so the catalog is never part of this MIT-licensed source tree.
