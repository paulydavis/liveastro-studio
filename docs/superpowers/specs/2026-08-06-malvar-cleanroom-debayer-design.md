# Clean-Room Malvar–He–Cutler Demosaic — Design

**Goal:** replace the current RCD demosaic path — a self-declared per-pixel port of
librtprocess `rcd.cc` (GPL-3.0) — with a **clean-room** implementation of the
Malvar–He–Cutler algorithm written solely from its published paper, so LiveAstro
Studio carries no GPL-derived code and can adopt a permissive (MIT) license.

**Why Malvar (owner decision 2026-08-06):** its coefficients are published as integer
filter masks in the paper (mathematical facts, not copyrightable expression), so
implementing from the paper is inherently clean — no taint wall to police. It is a
different algorithm from RCD, high quality (a large step above bilinear), linear,
deterministic, and fast.

**Source (the only permitted reference):** H.S. Malvar, L. He, R. Cutler,
"High-Quality Linear Interpolation for Demosaicing of Bayer-Patterned Color Images,"
IEEE ICASSP 2004. The coefficient masks in §3 below are transcribed from that paper.

## Clean-room provenance (binding process)

- The implementer MUST NOT read, open, or reference the existing RCD code in any form:
  `Sources/LiveAstroCore/Stacking/Debayer.swift`'s `rcd(...)` section, `scratchpad/rcd_debayer.py`,
  or any librtprocess/Siril source. The new algorithm is unrelated math; there is no
  legitimate reason to consult them.
- The implementer works ONLY from this spec plus the existing NON-RCD interface in
  `Debayer.swift` (the `bilinear(...)` path signature, `AstroImage`, `BayerPattern`,
  `DemosaicMethod`) needed to integrate.
- Correctness is verified against SYNTHETIC GROUND TRUTH (PSNR), never by comparing
  output to RCD or any GPL implementation.

## 1. Algorithm

Malvar–He–Cutler is gradient-corrected linear interpolation: bilinear interpolation of
the missing channel plus a correction term derived from the Laplacian of a KNOWN channel
at that site. Each missing colour at each CFA site is one 5×5 convolution with the
appropriate published mask, using clamped/mirrored edge handling. No iteration, no
thresholds, no channel ratios.

Five distinct masks cover every missing-value case; the four Bayer patterns
(GRBG/RGGB/BGGR/GBRG) are handled by the same index-offset scheme the `bilinear` path
already uses to identify each site's colour and its row/column parity.

## 2. Interface & migration

- `DemosaicMethod` (`Debayer.swift`): rename case `.rcd` → `.malvar`. Its raw value
  changes `"rcd"` → `"malvar"`; add Codable back-compat so a persisted `"rcd"` decodes
  to `.malvar` (never crashes). Display name "Malvar (high quality)".
- Add `public static func malvar(cfa: AstroImage, pattern: BayerPattern, minRows: Int = 64) -> AstroImage`
  with the SAME signature and edge/contract conventions as `bilinear(...)`
  (single-channel CFA in → 3-channel RGB out; images below the min pass through to
  bilinear; non-finite inputs sanitized as the bilinear path already does).
- Remove the entire `rcd(...)` implementation and its private helpers.
- `AppModel`'s quality default moves from `.rcd` to `.malvar` (the app keeps shipping a
  high-quality default, not bilinear). Any UI/`SessionSettings` string references to rcd
  update accordingly, with the decode back-compat above covering old saved settings.

## 3. Coefficient masks (from the paper; each applied to the interior, ÷ divisor)

Sites are named by the pixel's OWN colour and the missing colour being estimated.

**G at a R or B site** — divisor 8:
```
 0  0 -1  0  0
 0  0  2  0  0
-1  2  4  2 -1
 0  0  2  0  0
 0  0 -1  0  0
```

**R at a G site on a R row (B column)**, and symmetrically **B at a G site on a B row (R column)** — divisor 16:
```
 0  0  1  0  0
 0 -2  0 -2  0
-2  8 10  8 -2
 0 -2  0 -2  0
 0  0  1  0  0
```

**R at a G site on a B row (R column)**, and symmetrically **B at a G site on a R row (B column)** — divisor 16 (the transpose of the previous mask):
```
 0  0 -2  0  0
 0 -2  8 -2  0
 1  0 10  0  1
 0 -2  8 -2  0
 0  0 -2  0  0
```

**R at a B site**, and symmetrically **B at a R site** — divisor 16:
```
 0  0 -3  0  0
 0  4  0  4  0
-3  0 12  0 -3
 0  4  0  4  0
 0  0 -3  0  0
```

Each mask sums to its divisor (unity gain). The known channel at a site is copied
through unchanged. A 2-pixel border where the 5×5 window leaves the image delegates to
the existing `bilinear` result (same border strategy the RCD path used for its interior
cutoff — a structural convention, not RCD code).

## 4. Verification (the correctness gate — no GPL comparison anywhere)

- **Synthetic PSNR harness (new test):** take a deterministic synthetic RGB image with
  smooth regions AND hard edges/stars; for EACH of the four patterns, sample it into a
  CFA (drop the two missing channels per site), run `malvar`, and compute per-channel
  PSNR vs the original. Gate: Malvar's mean PSNR exceeds `bilinear`'s on the same image
  by a clear margin (the paper reports ~5 dB; assert ≥ 3 dB to allow content variance),
  proving the gradient correction is active and correct. Wrong coefficients or wrong
  pattern mapping fail this immediately.
- **Bayer-phase pin:** the existing bottom-up GRBG regression test (no R/B swap) must
  pass for `malvar` as it does for the other paths — same `normalizeRowOrder: false`
  contract.
- **Contracts:** strength/passthrough parity with bilinear (tiny image → bilinear; NaN/Inf
  sanitized; deterministic same-input-same-output); mono/unknown inputs unaffected.
- **Full suite** green; the removal of the RCD path must not break any test that named
  `.rcd` (those get updated to `.malvar` as part of the migration, not weakened).

## 5. Licensing housekeeping (same branch, after the algorithm lands)

- Add a top-level `LICENSE` file (MIT, Paul Davis, 2026).
- Delete `scratchpad/rcd_debayer.py` (the tainted prototype).
- Add a short `NOTICE`/README credit: Malvar–He–Cutler (ICASSP 2004) for the demosaic
  math; no third-party code is vendored.
- Removal is HEAD-only (owner decision): past commits/tags are left as-is; v3.1.0 stands.
- Update the CHANGELOG under a new Unreleased entry.

## 6. Non-goals

No new demosaic UI beyond the renamed method; no change to bilinear; no stacking/registration
changes; no git-history rewrite; RCD is not kept as a fallback (fully removed).
