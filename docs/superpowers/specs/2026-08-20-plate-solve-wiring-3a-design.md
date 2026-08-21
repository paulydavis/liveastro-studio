# Plate-Solve Wiring (sub-project 3a) — Design

**Date:** 2026-08-20 · **Status:** draft, pending user review
**Parent pillar:** native plate-solve / north-up. Catalog ✓ → solver ✓ (validated + hardened on a real
M63 sub) → **wire-in (3a)** → north-up display + UI (3b) → catalog download-on-demand (3c).

## Why 3a is its own spec

Sub-project 3 splits into three loosely-coupled pieces. 3a is the pure backend: run the (already
proven) solver off the hot path when the reference frame is established, and expose the resulting
`WCS`. It has **no UI and no orientation math**, so it needs none of the UX decisions 3b/3c do, and it
unblocks both. It is fully unit-testable end-to-end.

## What already exists (no new plumbing)

- `StackEngine` holds `referenceStars: [Star]` + `referenceSize: (w,h)` — the reference frame's detected
  stars, in **half-resolution** coordinates (detection runs on the half-res luminance).
- `SessionPipeline.sourceMetadata: SourceMetadata?` — captured from the first frame's FITS header;
  already carries `ra`, `dec` (decimal degrees), `focalLengthMM`, `pixelSizeUM`.
- `StarCatalog.bundled()` — returns the catalog or nil (nil today: placeholder; real catalog arrives via 3c).
- `PlateSolver.solve(stars:width:height:pixelScaleArcsec:approxCenterRA:approxCenterDec:catalog:)` — proven.

So 3a only connects these; it introduces no new metadata reading or frame handling.

## Components

### 1. `StackEngine` — expose the reference solve input (thread-safe)

```swift
/// The reference frame's detected stars + dimensions, in HALF-RES coordinates (detection runs on the
/// half-res luminance). nil until a reference is seeded. Read under the same lock as the rest of the
/// engine's reference state. Consumers solving against a catalog must double the pixel scale to match
/// the half-res coordinate space (a half-res pixel subtends 2× the sky).
public func referenceSolveInput() -> (stars: [Star], width: Int, height: Int)?
```

Returns nil when `referenceStars` is empty or `referenceSize` is nil. No copy of internals leaks beyond
the value tuple.

### 2. `SessionPipeline` — the solve coordinator (off the hot path)

- New state: `private var solvedWCS: WCS?` (guarded by the existing pipeline queue/lock), plus a
  `private var solveAttempted: Bool` so we try once per reference generation.
- **Trigger:** at the end of `finalizeCommitted` (where `sourceMetadata` is first captured and a
  reference exists), if `solvedWCS == nil && !solveAttempted`, attempt a solve. Set `solveAttempted`
  true regardless of outcome so we don't re-run every frame.
- **Guards (all must hold, else skip silently — plate-solve is optional):** `StarCatalog.bundled()`
  non-nil; `sourceMetadata` has `ra`, `dec`, `focalLengthMM > 0`, `pixelSizeUM > 0`;
  `engine.referenceSolveInput()` non-nil.
- **Scale:** `fullResScale = pixelSizeUM / focalLengthMM * 206.264806`; `halfResScale = fullResScale * 2`
  (stars/dims are half-res). Solve in half-res space — the recovered center (a sky position) and
  rotation (scale-invariant) are unaffected by working half-res.
- **Off the hot path:** dispatch the solve on a background queue (it takes ~1 s). On completion, store
  `solvedWCS` back on the pipeline queue. The import/commit loop never blocks on it.
- **Reseed:** wherever the reference resets (engine reseed), clear `solvedWCS = nil`, `solveAttempted =
  false` so the new reference re-solves.

### 3. `SessionPipeline` — expose the result

```swift
/// The plate-solved WCS for the current reference frame, or nil if not (yet) solved / no catalog /
/// missing metadata. 3b reads this to orient the display north-up.
public var currentWCS: WCS? { /* returns solvedWCS under the queue */ }
```

Optionally a lightweight status enum later (`notAttempted / solving / solved / failed / noCatalog`) for
3b's UI — deferred to 3b so 3a stays minimal.

## Data flow

```
first frame → sourceMetadata (ra,dec,focal,pixsz) captured
reference seeded in StackEngine → referenceStars (half-res)
finalizeCommitted → [guards pass] → background PlateSolver.solve(halfResStars, halfResScale, ra, dec, catalog)
                                  → solvedWCS stored → currentWCS exposes it
reseed → solvedWCS/solveAttempted cleared → re-solve on next reference
```

## Testing

- **Coordinator end-to-end (the key test):** build a synthetic session — a small in-memory catalog and
  a handful of synthetic FITS subs whose headers carry known `RA`/`DEC`/`FOCALLEN`/`XPIXSZ` and whose
  star field is the catalog projected through a known WCS. Run the pipeline; assert `currentWCS`
  eventually recovers the known center within ~arcmin and rotation within ~0.2°. (Reuses the synthetic
  projection helper from `PlateSolverTests`.)
- **No catalog → nil:** with the placeholder catalog (`bundled()` nil), `currentWCS` stays nil, no crash,
  import unaffected.
- **Missing metadata → nil:** subs without `FOCALLEN`/`RA` → no solve, `currentWCS` nil.
- **Half-res scale:** a focused test that the doubled scale is what makes the recovered center correct
  (a single-res scale would misplace it) — guards the 2× factor against silent regressions.
- **Reseed re-solves:** after a reseed with a different center, `currentWCS` updates to the new center.
- **Off the hot path:** the solve must not block commit — assert the import completes without waiting on
  the (slow) solve (e.g. the solve result may lag the final frame and still land).

## Non-goals (3a)

- Any display rotation / north-up / CGImage orientation — 3b.
- The "North up" toggle, status UI, or user-facing controls — 3b.
- Downloading the catalog / first-run prompt / hosting — 3c (until then `bundled()` is nil and 3a is a
  correct no-op).
- Per-frame solving (the reference solves once per generation; the stack inherits it).

## Open decisions carried to 3b / 3c (flagged, not needed for 3a)

- **3b:** solve trigger surfaced to the user (auto vs manual), whether north-up auto-applies or is a
  toggle, whether the recap/snapshots inherit the orientation, and the exact screen transform
  (reconciling the top-down display convention + parity — to be confirmed visually).
- **3c:** where the app downloads the ~32 MB catalog from (recommend: a pre-built LASC on the repo's
  GitHub Releases), the first-run prompt, and the cache location (Application Support). Also the
  release-script bundle-copy landmine (the packaged app must find the catalog).
