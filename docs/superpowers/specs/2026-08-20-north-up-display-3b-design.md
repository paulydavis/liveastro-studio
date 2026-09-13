# North-Up Display (sub-project 3b) — Design

**Date:** 2026-08-20 · **Status:** draft, pending user review
**Parent pillar:** native plate-solve / north-up. catalog ✓ · solver ✓ · 3a solve-wiring ✓ → **3b
north-up display** → 3c catalog download-on-demand.

**Goal:** When a plate solve is available (`SessionPipeline.currentWCS`), let the user orient the
broadcast display **north-up** with a toggle. The rotation flows through the single display render path
so the broadcast window, `latest.png`, snapshots, and the recap video all inherit it.

## Decisions (settled)

- **Trigger:** a **"North up" toggle, default OFF.** Nothing rotates until the user flips it. Safe for a
  live broadcast — the solve lands a few frames in, and auto-rotating would visibly spin the stream.
- **Scope:** the **display chain only** — everything produced by `displayCGImage` (broadcast, `latest.png`,
  snapshots, recap). `master.fit` stays in native orientation (science data product; rotating it would
  resample/degrade it for no broadcast benefit — WCS header keywords can make it north-aware later).
- **Framing (rotated image → 16:9):** **auto-zoom.** A near-90° rotation of a 3:2 sensor turns the frame
  portrait; the rotation itself also leaves black triangular corners. So: when the rotation is **small**
  (≤ `autoZoomMaxAngle`, ~15°) crop to the largest inscribed rectangle (fills, no black corners); when
  **large**, keep the full rotated bounding box (letterbox — never crop the object out).

## Components

### 1. `DisplayAdjustments.northUp: Bool` (default false)
`Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift` — add `public var northUp: Bool` to the struct,
`.neutral`, the memberwise init, and Codable (with a decode default so old saved sessions load). Already
synced app↔pipeline via the existing `displayAdjustments` plumbing — no new transport.

### 2. `NorthUpRotation` — the pure transform (`Sources/LiveAstroCore/PlateSolve/NorthUpRotation.swift`)
A small pure helper so the geometry is unit-testable in isolation:
- `displayRotationRadians(wcs: WCS) -> Double` — the angle to rotate the **displayed (top-down)** image so
  celestial north points up and east points left, from `wcs.rotationDegrees` + `wcs.parity`.
- `apply(_ cg: CGImage, wcs: WCS, autoZoom: Bool) -> CGImage` — rotate via CoreGraphics into a new context;
  if `autoZoom` and `|angle|` small, crop to the largest inscribed axis-aligned rectangle (removes the
  black corners); else return the full rotated bounding box.
- Constant `autoZoomMaxAngle` (~15°, documented) — the small/large threshold.

**The sign/parity/row-order reconciliation is determined EMPIRICALLY, not hand-derived.** The display is
top-down (`MasterBuilder` masters are `normalizeRowOrder: true`) while the solver ran on the native y-up
frame, and the exact chain (FITS ROWORDER → stored → normalize → display) is implementation-specific. The
build validates it by rendering the real M63 solve north-up and asserting north points up (§Testing), and
adjusting the sign/flip until it does — the test is the source of truth, not a derivation.

### 3. Rotation in the display path (`SessionPipeline.displayCGImage`)
After `makeCGImage(display)` (SessionPipeline ~:507), if `adj.northUp`, read `currentWCS`; when non-nil,
return `NorthUpRotation.apply(cg, wcs: wcs, autoZoom: true)`; when nil (not solved), return the image
un-rotated (toggle on but nothing to orient — no-op, no error). Purely a display transform: the linear
`AstroImage` used for stats/master is untouched.

### 4. Toggle availability exposed to the app
The toggle should be **enabled only when a solve is available**. Expose it: add
`SessionPipeline.hasSolvedWCS: Bool { currentWCS != nil }` (already have `currentWCS`) and surface it to
`AppModel` the same way other pipeline state reaches the UI (a poll on the existing display-update tick or
an `AppSurface` accessor). `AppModel.northUp` (Bool) drives `displayAdjustments.northUp` via the existing
`applyDisplayAdjustments()`.

### 5. UI — "North up" toggle in `ControlView`
In the Display Adjustments section, a `helpToggle("North up", isOn: $model.northUp, help: "…")` (same
pattern as Neutralize background), `.disabled(!model.solveAvailable)` with help text explaining it needs a
plate solve. When disabled, show a subtle "solving…/no catalog" hint.

## Data flow
```
currentWCS (from 3a) ─┐
displayAdjustments.northUp (toggle) ─┤
displayCGImage(mean) → stretch → makeCGImage → [northUp && solved?] → NorthUpRotation.apply → CGImage
                                                                              │
        broadcast window ◄── latest.png ◄── snapshot ◄── recap  (all inherit)
```

## Testing
- **Transform geometry (numeric, the core):** for a synthetic `WCS` (known rotation + both parities), a
  celestial-north offset from center must map to **above** the image center after `displayRotationRadians`
  is applied (and east to the left). Cover both parities and several rotation angles. This pins the sign
  without a real frame.
- **Auto-zoom framing:** small angle → output has no black-corner pixels (largest inscribed rect);
  large angle → output is the full rotated bounding box (dimensions match the rotated extent). Assert on
  output dimensions + corner-pixel checks.
- **Toggle gating:** `northUp = true` with `currentWCS == nil` → `displayCGImage` returns the image
  un-rotated (no-op); with a solved WCS → rotated. `solveAvailable` reflects `currentWCS != nil`.
- **Inherit-everywhere:** with `northUp` on + a solved session, `latest.png` and a snapshot are rotated
  consistently with the broadcast image (same orientation).
- **Gated real-frame visual (env `LAS_SOLVE_FRAME` + real catalog):** render the M63 master north-up and
  assert north is up — projected catalog stars, transformed through the same display rotation, land at
  their expected up/left positions. This is the empirical source of truth for the sign/parity/row-order.

## Non-goals (3b)
- Rotating/altering `master.fit` (native orientation stays; WCS-in-header is a later idea).
- Auto-orient (no toggle) — explicitly chose default-off toggle.
- Blind solve / re-solve triggers — that's 3a; 3b only consumes `currentWCS`.
- Catalog download / first-run — 3c (until then `currentWCS` is nil for the shipped app, so the toggle is
  simply disabled — 3b is a correct, inert feature until 3c lands the data).

## Open (carried to 3c)
Catalog hosting + first-run download + the release-script bundle-copy landmine — 3b's toggle stays
disabled until the catalog exists, so 3b ships safely ahead of 3c.
