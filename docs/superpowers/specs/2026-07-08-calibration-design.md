# LiveAstro Studio — Calibration Design

**Date:** 2026-07-08 · **Status:** approved for planning

## 1. Goal

Calibrate raw CFA frames with master dark / flat / bias frames **before debayer**,
in both native import and live stacking modes, using the matched-frame recipe
validated in Python on the IC 443 dataset (session `ic443jellyfishcal`, 100/100
accepted). Masters can be **built in-app** from raw calibration folders *or*
**loaded pre-built** (e.g. from Siril/APP), independently per master. Last-used
master paths are remembered between sessions. This is the biggest missing pillar
on the mature-stacker roadmap.

## 2. Decisions (made 2026-07-08 with Paul)

| Decision | Choice |
|---|---|
| Master source | **Both** — build in-app from raw folders AND accept pre-built master files, chosen independently per master. A built master is saved as `.fit`, so "load pre-built" is the same apply path with the build step skipped. |
| Master management | **Remembered defaults** — built masters persist as `.fit` on disk; last-used paths saved in `UserDefaults` and pre-filled at session setup. No metadata-matching engine (that is the ledgered "persistent auto-matching library" upgrade). |
| Recipe | **Matched-frame, no scaling** — `cal = (light − masterDark) / masterFlatNorm` on the raw CFA. Each master optional. No dark-scaling, dark-optimization, or hot-pixel map. |
| Master build | **One-time, persists** — combining is done once (whenever new calibration frames are shot); the master is saved and thereafter referenced as a file. Building runs off the main thread. |
| Master-build UX | **Inline** in the session-setup Calibration section (not a separate tool). |
| Integration seam | **Pipeline step** — `SessionPipeline` holds an optional `Calibrator`, applied in `handleNative` before `engine.process`. `StackEngine` unchanged. |
| Master store location | Default `~/LiveAstro/masters/`. |

## 3. Recipe (validated)

Python prototype (`scratchpad/calibrate_ic443.py`), reproduced in normalized
[0,1] space. The recipe is scale-invariant, so working in [0,1] (Swift
`AstroImage`) rather than uint16 ADU (Python) yields the identical result as
long as dark and light share a scale and the flat is normalized:

- `masterDark = mean(darks)` — contains bias + dark current + amp glow.
- `masterFlat = mean(flats [− masterBias if present])`, clamped ≥ ε, then
  **normalized to median 1** (a dimensionless per-pixel multiplier).
- `masterBias = mean(biases)` — used **only** to clean the flat. At the short
  flat exposures used (~0.75 s), bias ≈ flat-dark, so a bias master suffices as
  the flat's dark; a separate flat-dark is a non-goal.
- Per light: `cal = (light − masterDark) / masterFlatNorm`, clamp to [0,1],
  non-finite → 0.

Each master is optional and the recipe degrades gracefully:
- dark only → `light − dark`
- flat only → `light / flatNorm`
- dark + flat → `(light − dark) / flatNorm`
- bias present → cleans the flat during build (never applied to lights directly)

## 4. Architecture

```
Sources/LiveAstroCore/Calibration/         (new)
  MasterKind.swift    (enum: dark, flat, bias)
  MasterFrame.swift   (struct: image + bottomUp row order)
  MasterBuilder.swift (folder of FITS → master AstroImage; save/load .fit)
  Calibrator.swift    (holds optional dark/flat masters; apply(RawFrame)→RawFrame)

Sources/LiveAstroCore/Pipeline/
  SessionPipeline.swift  (new optional `calibrator` + native init param)

Sources/LiveAstroStudio/
  ControlView / SessionProfileForm  (new "Calibration" section)
  AppModel / persistence            (remembered master paths in UserDefaults)
```

### 4.1 MasterKind & MasterFrame

```swift
public enum MasterKind { case dark, flat, bias }

/// A master calibration frame in SENSOR (stored) row order — the same order as
/// the raw lights it calibrates. `bottomUp` records that order so the Calibrator
/// can align it to each incoming light.
public struct MasterFrame {
    public let image: AstroImage    // 1-channel CFA (or mono), sensor order
    public let bottomUp: Bool
    public init(image: AstroImage, bottomUp: Bool)
}
```

### 4.2 MasterBuilder

```swift
public enum MasterBuilder {
    /// Mean-combine FITS frames into a master, in sensor (stored) order.
    /// - For .flat: subtracts `bias` per-frame when provided, then normalizes
    ///   the mean to median 1 after clamping to ≥ epsilon.
    /// - O(1) memory: running Double sum ÷ count; frames are not retained.
    /// - Throws if `fitsURLs` is empty or every frame mismatches the first
    ///   frame's dimensions.
    public static func combine(fitsURLs: [URL], kind: MasterKind,
                               bias: AstroImage?) throws -> MasterFrame

    /// Save a built master as Float32 FITS. Records its row order in the header.
    public static func save(_ master: MasterFrame, to url: URL) throws

    /// Load a pre-built master file (sensor order + ROWORDER-derived bottomUp).
    public static func load(_ url: URL) throws -> MasterFrame
}
```

- **Row order:** frames are read with `normalizeRowOrder: false` (sensor order,
  never flipped) so masters match the CFA order the stacker consumes. The frame's
  `bottomUp` comes from the FITS `ROWORDER` header, exactly as `RawFrame.bottomUp`.
- **Accumulation:** a `[Double]` running sum guards against precision loss over
  100+ frames; divide by count for the mean.
- **Flat normalization:** after (optional) bias subtraction and mean, clamp each
  pixel to ≥ `flatFloor` to avoid divide-by-zero, then divide the whole frame by
  its median so the master is a ~1.0 multiplier. `flatFloor = 1.0 / 65535`
  (1 ADU at 16-bit; `FITSReader` maps physical value ÷ 65535 → [0,1], so 1.0 =
  full scale) — the normalized equivalent of the prototype's `clip(flat, 1.0)`.
- **Dimension policy:** the first successfully-read frame sets the reference
  dimensions; later frames that differ are skipped and counted; if none remain,
  throw. Row order is assumed consistent within a folder (same camera/software).

### 4.3 Calibrator

```swift
public final class Calibrator {
    public init(dark: MasterFrame?, flat: MasterFrame?)

    /// Calibrate one raw frame's CFA. Returns the frame unchanged when no
    /// masters apply. Never throws — a mismatched master is skipped (logged
    /// via `onLog`) so calibration can never break the session.
    public func apply(_ frame: RawFrame) -> RawFrame

    public var onLog: ((String) -> Void)?
}
```

- **Math** (per pixel, normalized [0,1]): `out = (light − dark) / flatNorm`,
  clamp [0,1]; if `!out.isFinite` → 0 (NaN-poisoning guard). `flatNorm` pixels
  are re-clamped ≥ `flatFloor` at apply time too, in case a *pre-built* external
  flat contains zeros the build clamp never saw.
- **Orientation (the #1 correctness risk):** calibration is a per-pixel op, so a
  master and the light must share row order. On the first `apply`, each master
  whose `bottomUp` differs from the frame's is flipped once and the aligned copy
  cached (all frames in a session share `bottomUp`, so this happens at most once
  per master). A **bottom-up regression test** pins this, mirroring the CFA R/B
  discipline already in the codebase.
- **Dimension mismatch:** a master whose dims differ from the frame's is dropped
  for that frame (logged once), and the remaining masters still apply. The frame
  is never rejected on calibration grounds.

### 4.4 SessionPipeline integration

- New stored `private let calibrator: Calibrator?` and a `calibrator:` parameter
  on the **native** initializer (default `nil`, preserving existing callers).
- `handleNative(_:engine:)` calibrates first:
  ```swift
  let frame = calibrator?.apply(raw) ?? raw
  let outcome = engine.process(frame)
  ```
  Everything downstream (luminance, debayer, registration, accumulation,
  snapshot, `master.fit`) is unchanged and now operates on calibrated data.
- The `Calibrator.onLog` is wired to the pipeline's `onLog`.
- Watcher mode is untouched (calibration is a native-stacking concern).

### 4.5 UI — Calibration section (native session setup)

A new "Calibration" section, shown in native (raw-subs) mode:

- Three rows — **Dark**, **Flat**, **Bias** — each with a state of *None* /
  *Build from folder…* / *Use file…*:
  - **Build from folder…** → folder picker → combine **off the main thread**
    with visible progress ("combined N / total") → save to `~/LiveAstro/masters/`
    → the row shows the saved file and frame count.
  - **Use file…** → file picker → a pre-built master `.fit`.
- The Bias row carries the note *"used to clean flats"* (it is never applied to
  lights directly).
- Last-used master file paths are pre-filled from `UserDefaults`. A remembered
  path whose file is missing shows a warning and is treated as *None*.
- On **Start Session**, the selected/built masters construct a `Calibrator`
  passed into the native `SessionPipeline`. No masters selected → `calibrator`
  is `nil` and behavior is exactly as today.

## 5. Data flow

```
Session setup: select/build masters ──► Calibrator(dark?, flat?)
        │                                        │
        └─ save built masters to ~/LiveAstro/masters/ (+ remember paths)
                                                 │
Start Session ──► SessionPipeline(nativeSource:, engine:, calibrator:)
                                                 │
per frame:  FrameSource emits RawFrame (raw CFA, sensor order)
        ──► calibrator.apply  ((L−D)/F, clamp, align row order)
        ──► engine.process     (halfRes luminance → debayer → register → accumulate)
        ──► snapshot + manifest + master.fit
```

## 6. Error handling

| Situation | Behavior |
|---|---|
| Build set empty / all frames mismatch dims | `MasterBuilder.combine` throws → surfaced in setup UI ("can't build"); session not started with that master |
| Master dims ≠ light dims at apply | that master skipped for the frame, logged once; session continues uncalibrated-by-that-master |
| Flat pixel ≤ 0 (external pre-built flat) | clamped to `flatFloor` at apply; no divide-by-zero |
| Non-finite calibration result | mapped to 0 (NaN-poisoning guard) |
| Remembered master file moved/deleted | setup warns, treats as *None* |
| Build in progress | runs off the main thread; UI shows progress; failure logged, non-fatal |

Calibration failures **never** propagate into the stacking/session path — same
"never break the astronomy" invariant as the OBS layer.

## 7. Testing

**MasterBuilder** — mean-combine correctness (known frames → known mean); flat
path (bias subtracted, mean, clamp, normalize → median exactly 1); dimension
mismatch skipped and counted; empty / all-mismatch set throws; save→load round
trip preserves pixels and row order.

**Calibrator** — exact `(L−D)/F` on synthetic data (a dark that removes a known
pedestal; a flat that removes a known gradient); identity passthrough with no
masters; dimension-mismatch skip leaves the frame otherwise intact; flat-zero
clamp (no NaN/Inf); non-finite input → 0; **row-order alignment** (a bottom-up
master applied to a top-down light lines up pixel-for-pixel).

**SessionPipeline integration** — native e2e: a `FrameSource` emitting frames
with a known additive pedestal + a matching master dark → the accumulated
`master.fit` shows the pedestal removed relative to the uncalibrated run.

**UI** — `UserDefaults` persistence of remembered paths is unit-tested. Folder/
file pickers, build progress, and off-main-thread combine are **manual
validation**, documented in the README dev section per house rules.

## 8. Non-goals (ledgered mature-stacker follow-ups)

Dark scaling / dark optimization; hot-pixel & cosmetic correction; a persistent
auto-matching master **library** (catalog masters by camera/exposure/temp/gain
and auto-apply from light headers); separate flat-darks distinct from bias;
CFA-phase-aware or per-channel flat handling (whole-CFA flat is correct here);
drizzle. Winsorized κ-σ rejection is a separate, already-specced pillar.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Row-order mismatch between master and light (silent vertical flip → garbage calibration) | Calibrator aligns masters to each frame's `bottomUp`; bottom-up regression test pins it |
| Precision loss mean-combining 100+ frames | `Double` running-sum accumulator |
| Pre-built external flat with zero pixels | `flatFloor` clamp at both build and apply |
| Long build blocking the UI | off-main-thread combine with progress; masters persist so build is one-time |
| Value-scale confusion (uint16 prototype vs [0,1] Swift) | recipe is scale-invariant; documented; dark/light same scale, flat normalized dimensionless |
