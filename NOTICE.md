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
