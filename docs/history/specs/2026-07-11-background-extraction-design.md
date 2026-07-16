# LiveAstro Studio — "Native Background Extraction (DBE)" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** the Bortle-7 light-pollution gradient that survives on the live
stack (Veil nights) — the Display Adjustments pillar gave uniform *global*
knobs; this removes the *spatial* gradient so the sky darkens evenly without
touching nebula signal. Second of the two "make stacks look good" pieces.

## 1. Goal

Flatten the uneven light-pollution gradient in the **displayed** image (live
view + snapshots + replay) by modeling the sky background as a smooth 2D surface
and subtracting it. Nebula signal and the linear `master.fit` are untouched.

## 2. Core principles (settled 2026-07-11 with Paul)

- **Display-path only.** DBE runs inside `displayCGImage`, on linear data before
  the stretch. `master.fit` stays linear/unadjusted (clean-export philosophy;
  the user's own PixInsight / the shipped GraXpert processor handle the master).
- **Conservative by construction.** A low-order polynomial (planar or quadratic)
  can only represent a smooth ramp/bowl, so it physically cannot subtract a
  non-smooth nebula. This is the honest-gradient-remover choice over a flexible
  spline that could eat a large extended object.
- **Opt-in, measured default.** Off by default; degree 1 (planar) default when
  on. No blind auto-tuning (the validated over-processing lesson).
- **Reuse the tile machinery.** The sampling grid + per-tile median already exist
  in `AutoStretch.neutralizeBackgroundAdditive`; DBE is the spatial upgrade from
  "one background value per channel" to "a fitted surface per channel."

## 3. Decisions

| Decision | Choice |
|---|---|
| Scope | **Display path only** (live/broadcast + snapshots + replay); `master.fit` stays linear |
| Method | **Polynomial ABE** — tile-sample sky → sigma-clip bright tiles → least-squares 2D polynomial fit → subtract + pedestal, per channel |
| Degree | User picks **1 (planar tilt)** or **2 (quadratic / vignette)**; default 1 |
| On/off | Toggle, **default off**; persisted |
| Params home | Extend the shipped `DisplayAdjustments` value type (rides the existing render + persistence plumbing) |
| Ordering | DBE on linear **before** neutralize + stretch |
| Neutralize interaction | When DBE on, **skip the additive** neutralize (DBE already removes per-channel background); **multiplicative** white-balance neutralize still applies if its toggle is on |

## 4. Data flow

`SessionPipeline.displayCGImage(from linear:)` becomes:
```
adj = displayAdjustments (single locked read, as today)
img = adj.backgroundExtraction
      ? BackgroundExtraction.flatten(linear, degree: adj.backgroundDegree)
      : linear
balanced = neutralizeBackground
      ? (adj.backgroundExtraction
            ? AutoStretch.neutralizeBackground(img)                       // multiplicative only
            : AutoStretch.neutralizeBackground(AutoStretch.neutralizeBackgroundAdditive(img)))
      : img
stretched = balanced.sourceIsLinear ? AutoStretch.stretch(balanced, blackPoint:…, midtoneStrength:…) : balanced
display  = AutoStretch.applySaturation(stretched, adj.saturation)
→ makeCGImage
```
The master-finalize path is **not** touched. Snapshots + replay flow through
`displayCGImage`, so they inherit DBE.

## 5. Architecture

```
LiveAstroCore/
  Imaging/
    BackgroundExtraction.swift   (NEW: pure flatten(_:degree:) + the polynomial fit)
    DisplayAdjustments.swift     (+ backgroundExtraction: Bool, backgroundDegree: Int; custom backward-compat Codable)
  Pipeline/
    SessionPipeline.swift        (displayCGImage: DBE step + neutralize interaction)
LiveAstroStudio/
    ControlView.swift            (+ "Flatten background (DBE)" toggle + Planar/Quadratic picker)
```

### 5.1 `BackgroundExtraction` (pure, testable)

```swift
public enum BackgroundExtraction {
    /// Flatten a smooth background gradient by fitting a per-channel low-order 2D
    /// polynomial to sky-tile samples and subtracting it. degree 1 = planar,
    /// 2 = quadratic. Returns the image UNCHANGED on any condition that makes a
    /// fit unsafe (see §6). Operates on linear [0,1] data; preserves dims/channels.
    public static func flatten(_ image: AstroImage, degree: Int,
                               tilesPerAxis: Int = 32,
                               rejectionSigma: Double = 2.0) -> AstroImage
}
```
Per channel:
1. **Tile samples** — split into `tilesPerAxis²` tiles; each tile → (cx, cy,
   median) where cx,cy are the tile-center coordinates normalized to [-1,1]
   (centering improves the fit's numerical conditioning).
2. **Reject bright tiles** — compute the median and MAD of the tile medians;
   iteratively drop tiles whose median > center + `rejectionSigma`·MADN (a few
   passes, MADN = 1.4826·MAD). Survivors are sky.
3. **Fit** — least-squares solve for the polynomial coefficients over the sky
   tiles. Basis: degree 1 → {1, x, y}; degree 2 → {1, x, y, x², xy, y²}. Build
   the normal equations (AᵀA c = Aᵀb) and solve the small symmetric system with
   Gaussian elimination + partial pivoting (no external LAPACK; the system is
   3×3 or 6×6).
4. **Subtract + pedestal** — evaluate `surface(x,y)` per pixel; compute
   `pedestal = min over pixels of surface`; `out = clamp(pixel − surface + pedestal, 0, 1)`.
   Re-adding the surface minimum keeps the darkest sky just above 0 rather than
   crushing to black, and preserves relative structure.

### 5.2 `DisplayAdjustments` extension

Add two fields (defaults keep the neutral look):
```swift
public var backgroundExtraction: Bool   // default false
public var backgroundDegree: Int        // default 1
```
`.neutral` includes `backgroundExtraction = false, backgroundDegree = 1`.
Add a **custom `init(from:)`** using `decodeIfPresent(...) ?? default` for every
field (so an old blob lacking the new keys still decodes; matches the
SessionSettings pattern). Values still un-clamped in the memberwise init;
`degree` is clamped to {1,2} on apply in `flatten`.

### 5.3 UI (`ControlView`)

In the existing "Display Adjustments" section: a **"Flatten background (DBE)"**
`Toggle` bound to `$model.displayAdjustments.backgroundExtraction`, and a
segmented **Planar | Quadratic** picker bound to `backgroundDegree` (1/2),
disabled when the toggle is off. Both trigger `model.applyDisplayAdjustments()`
(the shipped throttled off-main re-render). `.help()` tooltips.

## 6. Error handling (all → return image unchanged, passthrough)

| Situation | Behavior |
|---|---|
| `image.channels != 3` | passthrough (mono display path unchanged) |
| degree not in {1,2} | clamp to nearest valid (1 or 2) |
| fewer surviving sky tiles than fit coefficients (3 or 6) | passthrough (can't fit) |
| singular / ill-conditioned normal equations | passthrough |
| all-zero or all-equal channel | its surface is flat → subtract adds nothing (safe) |

No throw path; the function always returns a valid same-dimension image.

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **Gradient removed (TDD):** synthetic 3-channel linear image = flat sky
  (e.g. 0.1) + a known planar ramp across x → after `flatten(degree: 1)` the
  background is flat to a tight tolerance (max−min over a sky region ≪ the
  original ramp amplitude).
- **Nebula preserved:** the same image with a bright Gaussian "nebula" blob →
  after flatten, the blob's peak-minus-local-background is preserved within
  tolerance (the polynomial didn't eat it), and the blob region's tiles were
  rejected from the fit.
- **Quadratic needs degree 2:** an image with a curved (quadratic) gradient is
  left with residual curvature at degree 1 but is flat at degree 2.
- **Flat image ≈ unchanged:** a uniform image round-trips within tolerance
  (surface is constant → subtract+pedestal is ~identity).
- **Passthrough guards:** mono image unchanged; an image whose sky tiles are all
  rejected (too few survivors) returned unchanged.
- **`DisplayAdjustments` backward-compat:** an old JSON without the new keys
  decodes with `backgroundExtraction=false, backgroundDegree=1`; round-trip
  preserves set values; `.neutral` has DBE off.
- **Manual/build-verified:** the `displayCGImage` DBE+neutralize wiring and the
  ControlView toggle/picker (SwiftUI/window lifecycle out of unit scope, per the
  prior pillars). RELEASE build must succeed; neutral (DBE off) display output
  stays byte-identical to today (existing pipeline/e2e tests green).

## 8. Non-goals (future builds)

Sampled DBE with placed/auto-placed points + spline/RBF (the flexible method —
deferred; polynomial chosen for safety); baking DBE into `master.fit` (master
stays linear; GraXpert/PixInsight own that); per-region or masked extraction;
higher polynomial degrees (3+); a native background-extraction *Processor*
backend for the master (the GraXpert processor already covers offline master
DBE); auto-selecting the degree.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Polynomial eats a large smooth nebula | low degree (≤2) can't fit non-smooth structure; bright-tile sigma-clip removes nebula tiles from the fit; degree is user-controlled and reversible; master untouched |
| Over/under-subtraction crushes the background to black | pedestal = re-add surface minimum, clamp [0,1]; opt-in with a visible toggle |
| Double background subtraction (DBE + additive neutralize) | when DBE on, skip additive neutralize; keep only multiplicative white-balance |
| Perf on 26MP in the throttled re-render | tile medians + O(pixels) surface eval ≈ one extra pass; fit is a 3×3/6×6 solve; well within the existing stretch cost |
| Ill-conditioned fit from clustered/few sky tiles | center coords to [-1,1]; partial-pivot solve; passthrough on singular/too-few |
| DisplayAdjustments Codable change breaks old settings | custom `init(from:)` with `decodeIfPresent ?? default` for every field; a test decodes a pre-DBE blob |
