# LiveAstro Studio v2 — Native Stacking Design

**Date:** 2026-07-07 · **Status:** implemented (2026-07-07)

## 1. Goal

LiveAstro stacks sub-exposures itself — both **import** (a folder of acquired
subs → session + replay + master) and **live** (watch a folder as subs arrive,
stack in real time) — while the existing Siril-output mode remains fully
supported. No external dependencies; the porting reference is our validated
Python prototype (`Scripts/build_session_from_subs.py`), *not* Siril source
(GPL — we study behavior, never copy code).

## 2. Why

- Siril livestacking works but is fragile in the field (CWD bug, delivery
  sensitivities, hangs on quit — see the 2026-07-06 runbook gotchas).
- One stacker core serves every current and future frame source: Seestar SMB,
  ASIAIR SMB, and later direct ASCOM Alpaca capture from both of Paul's
  cameras (v3 — out of scope here, but the architecture must not preclude it).

## 3. Decisions (made 2026-07-07 with Paul)

| Decision | Choice |
|---|---|
| Scope | Import + live in one spec, shared core |
| Debayer | **Full-res bilinear** (print-quality masters; S30 Pro 3840×2160 IMX585, 2600-Air 6248×4176) |
| Rejection (live) | **Registration-failure only** — too few stars / no consistent transform → skip, log, count. No quality knobs. |
| Stacking method | Incremental mean (proven in prototype) |
| Alignment | Similarity transform (translation + rotation + scale) — alt-az field rotation is real |
| Reference frame | First accepted sub; **Reseed Reference** button restarts the accumulator from the newest sub (July 6 fog lesson) |
| Master output | End Session writes `master.fit` (32-bit float RGB, TOP-DOWN) alongside replay.mp4 |

## 4. Architecture

```
FrameSource (protocol)                     StackEngine
  FolderFrameSource (v2) ──raw frames──▶     debayer → register → accumulate
  AlpacaFrameSource (v3, not built)          │ (linear RGB stack state)
                                             ▼
                              SessionPipeline (existing)
                              neutralize/stretch → broadcast + snapshots
                              → manifest → replay + master at end
```

### 4.1 FrameSource protocol (`Sources/LiveAstroCore/Sources/FrameSource.swift`)

```swift
public protocol FrameSource {
    /// Emits raw (pre-debayer) frames as they become available, then finishes.
    var frames: AsyncStream<RawFrame> { get }
    func start() throws
    func stop()
}
public struct RawFrame {
    public let image: AstroImage      // 1-channel, linear, as stored
    public let bayerPattern: String?  // from FITS BAYERPAT (nil = mono)
    public let rowOrder: ROWORDERValue
    public let timestamp: Date        // DATE-OBS or file mtime
    public let sourceName: String
}
```

`FolderFrameSource` wraps the existing `StackFileWatcher` (live) or a sorted
directory enumeration (import); both paths produce identical `RawFrame`s.

### 4.2 StackEngine (`Sources/LiveAstroCore/Stacking/`)

Pure, UI-free, deterministic. Files:

- `Debayer.swift` — full-res bilinear demosaic. Input: 1-channel CFA image +
  pattern (GRBG and RGGB supported; pattern read from `BAYERPAT`, applied in
  **stored row order before any flip** — the phase-shift lesson from
  2026-07-06). Output: 3-channel `AstroImage`, same dimensions.
- `StarDetector.swift` — background/σ estimate (median + MADN on a grid),
  threshold at background + kσ, connected-component centroiding, return
  top-N stars by flux (default N = 60) with sub-pixel centroids.
- `TriangleMatcher.swift` — astroalign-style invariant matching: build
  triangles from brightest stars, hash by side-ratio invariants, vote for
  correspondences.
- `TransformSolver.swift` — RANSAC similarity-transform fit over matched
  pairs; success requires ≥ `minMatches` (default 8) inliers under
  `inlierTolerance` (default 2 px).
- `Warp.swift` — inverse-mapped bilinear resampling of a 3-channel image
  under a similarity transform (Accelerate/vImage where it fits; plain Swift
  fallback keeps tests hermetic).
- `StackAccumulator.swift` — planar Float32 running sum + count; `mean`
  yields the current stack; `reseed(with:)` restarts from a frame.
- `StackEngine.swift` — orchestration: debayer → detect → match vs reference
  → warp → accumulate; returns per-frame `StackOutcome` (`.stacked(n)` /
  `.rejected(reason)` / `.becameReference`).

Registration runs on the **luminance** (channel mean) at half resolution for
speed; the solved transform is applied to the full-res RGB (scale the
translation by 2). Star positions are resolution-independent after scaling.

### 4.3 Session integration

- `SessionPipeline` gains a mode: `.watchStackerOutput` (existing behavior,
  unchanged) or `.nativeStack(FrameSource)`. In native mode each
  `.stacked` outcome produces exactly what a Siril revision produced before:
  a stretched CGImage for the broadcast window + a snapshot + manifest row.
  Manifest stats stay linear/raw (cloud gate contract).
- `estimatedIntegrationSeconds` = acceptedCount × subExposure (true count,
  not file count — rejected subs don't inflate integration time).
- End Session: existing replay path + write `master.fit` via `FITSWriter`.
- Control window: source picker — "Stacker output folder (Siril)" vs
  "Raw subs folder (native stacking)"; native mode shows accepted/rejected
  counters and the **Reseed Reference** button. Import = "Import Subs…"
  button: pick folder, batch-run the same engine with a progress bar, session
  lands in `~/Documents/LiveAstro/` like any other.

## 5. Validation

1. **Unit level:** synthetic starfields with known similarity transforms —
   solver must recover rotation to 0.1° and translation to 0.5 px; debayer
   validated against hand-computed 4×4 CFA fixtures; accumulator is exact
   arithmetic.
2. **Prototype parity:** extend `build_session_from_subs.py` with a bilinear
   debayer mode; per-stage numeric comparison (star lists, transforms within
   tolerance, final stack pixel correlation ≥ 0.99) on 16 NGC 6888 subs.
3. **Ground truth:** full 120-sub NGC 6888 native stack vs Paul's Siril
   master — channel-wise correlation must meet or beat the Python prototype's
   result (GRBG winner from the 4-way labeling test).
4. **Performance gate:** one 2600-class frame (6248×4176) through the full
   engine in < 10 s on Apple Silicon (sub cadence is ≥ 20 s; S30 Pro frames
   are 4.6× smaller).
5. **Live e2e:** feed real S30 Pro subs through `FolderFrameSource` with the
   existing feed script; broadcast updates, cloudy sub rejected (fixture:
   one July-6 foggy sub), replay + master render.

## 6. Memory & performance notes

2600-Air worst case: full-res RGB Float32 ≈ 313 MB accumulator + one frame in
flight ≈ 630 MB peak — acceptable. Warping dominates CPU; vImage handles it.
Registration at half-res luminance keeps star detection cheap. Import mode
processes serially (no parallel frames — accumulator is ordered anyway).

## 7. Non-goals for v2

Dark/flat/bias calibration (Seestar/ASIAIR calibrate internally), sigma-clip /
winsorized stacking, drizzle, plate solving, mount/camera control, Alpaca
capture (v3), mono-camera filter workflows, meridian-flip handling beyond
what similarity registration already absorbs.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Triangle matching robustness on sparse fields | Same algorithm family as astroalign, which handled these exact subs; N=60 stars, RANSAC; fixture tests from real data |
| Full-res warp too slow on 26 MP | vImage; performance gate in §5; fall back to warp-at-half-res + upsample only if the gate fails (spec change, ask first) |
| Bilinear debayer color fringing vs Siril's RCD | Acceptable for v2; masters are for Paul, not publication; note in README |
| Live file completeness (partial writes) | Existing watcher minimum-size + digest logic already handles it |
