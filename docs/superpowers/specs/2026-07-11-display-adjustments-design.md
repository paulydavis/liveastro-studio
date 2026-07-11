# LiveAstro Studio — "Display Adjustments" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** Paul's Veil-night want — *"keep this kind of nebulosity and boost
contrast in the background a smidge."* Today the stretch is fully automatic
(AutoStretch MTF) with no manual knob. This adds non-destructive display sliders
that nudge the look on top of the auto-stretch. First of two "make stacks look
good" pillars; native DBE/gradient-extraction is the separate follow-on.

## 1. Goal

Give the user three non-destructive sliders — black-point, stretch strength,
saturation — that shape the **displayed** image (live/broadcast + snapshots +
replay) without touching the stacked accumulator data or the linear `master.fit`.
Neutral defaults reproduce today's image exactly.

## 2. Core principles (settled 2026-07-11 with Paul)

- **Non-destructive, display-path only.** Sliders modify `displayCGImage`; the
  `StackAccumulator` and the exported linear `master.fit` are never touched.
- **Master stays linear.** Adjustments never bake into `master.fit` — PixInsight
  / GraXpert / SPCC still get clean linear data (preserves the clean-export
  pillar's guarantee).
- **Nudge on top of auto.** Each slider defaults to a neutral value that
  reproduces the current auto-stretch look exactly; moving it adjusts relative to
  auto, not from scratch.
- **No blind auto.** These are user controls with measured neutral defaults —
  the validated lesson that a naive auto-metric over-processes.
- **Live feedback.** Dragging a slider re-renders the current stack immediately,
  without waiting for the next frame.

## 3. Decisions

| Decision | Choice |
|---|---|
| Slider set | **Black-point/shadow, Stretch strength (midtone), Saturation** — exactly the three Paul named |
| Effect scope | **Live/broadcast view + snapshot PNGs + replay.mp4**; `master.fit` stays linear & unadjusted |
| Baseline | Each slider **neutral by default** = today's auto-stretch image, byte-identical |
| Live update | Re-render `engine.currentStack()` on slider change, **throttled** (~10–15 fps), off-main |
| Persistence | `DisplayAdjustments` stored in `SessionSettings` (Codable, backward-compat decode → neutral) |

## 4. Data flow

Today `displayCGImage(from: linear)` (SessionPipeline.swift:113) does:
```
linear → (neutralize additive+mult if toggle) → AutoStretch.stretch → makeCGImage
```
New:
```
linear → (neutralize) → AutoStretch.stretch(blackPoint, midtoneStrength)
       → AutoStretch.applySaturation(sat) → makeCGImage
```
The per-frame live path, the snapshot path, and the replay all call
`displayCGImage`, so they inherit the adjustments. The `master.fit` write path
(SessionPipeline.swift:~241) does **not** call `displayCGImage` and is left
unchanged — linear master preserved.

## 5. Architecture

```
LiveAstroCore/
  Imaging/
    DisplayAdjustments.swift   (NEW: Codable value type + neutral default)
    AutoStretch.swift          (+ blackPoint/midtoneStrength params on stretch; + applySaturation)
  Pipeline/
    SessionPipeline.swift      (displayCGImage takes DisplayAdjustments; + renderCurrentDisplay(adjustments:))
  Settings/
    SessionSettings.swift      (+ displayAdjustments field, backward-compat decode)
LiveAstroStudio/
    AppModel.swift             (+ displayAdjustments; throttled re-render on change; load/save)
    ControlView.swift or LiveView (+ Display Adjustments section: 3 sliders + Reset)
```

### 5.1 `DisplayAdjustments` (value type)

```swift
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double       // 0 (neutral) … 0.2, shadow clip on linear data
    public var midtoneStrength: Double  // −1 … +1, 0 = neutral (auto midtone unchanged)
    public var saturation: Double       // 0 … 2, 1 = neutral (unchanged)
    public static let neutral = DisplayAdjustments(blackPoint: 0, midtoneStrength: 0, saturation: 1)
    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1)
}
```
Values are clamped to their documented ranges on apply (not in the initializer,
so a persisted out-of-range blob degrades gracefully).

### 5.2 `AutoStretch` extensions

- `stretch(_ image, blackPoint: Double = 0, midtoneStrength: Double = 0)` —
  extends the existing signature with **neutral-default** params so every current
  caller is unchanged.
  1. **Black-point:** on the linear image, `x' = max(0, (x − bp)/(1 − bp))` with
     `bp = clamp(blackPoint, 0, 0.2)`. `bp == 0` → identity. Applied per channel.
  2. Compute the auto MTF midpoint `m` from stats exactly as today.
  3. **Midtone strength:** `m' = clamp(m · pow(2, −clamp(midtoneStrength,−1,1)), 1e-4, 1−1e-4)`.
     `strength == 0` → `m' == m` → today's stretch exactly. Positive = brighter
     mids (harder stretch), negative = gentler.
  4. Apply MTF with `m'` as today.
- `applySaturation(_ image, _ factor: Double) -> AstroImage` — post-stretch, on
  the display-space [0,1] RGB. Per pixel: `L = 0.2126 R + 0.7152 G + 0.0722 B`;
  `out_c = clamp(L + clamp(factor,0,2)·(c − L), 0, 1)`. `factor == 1` → identity.
  **Mono (1-channel) passthrough** (no chroma to scale).

### 5.3 `SessionPipeline`

- `displayCGImage(from linear:, adjustments: DisplayAdjustments)` — threads the
  adjustments through the stretch + saturation step. Callers in the live/import
  frame handlers pass the pipeline's current adjustments.
- `renderCurrentDisplay(adjustments: DisplayAdjustments) -> CGImage?` — re-runs
  `displayCGImage` on `engine.currentStack()` (nil if no stack yet). This is the
  live-feedback entry point; read-only on accumulator state.

### 5.4 `AppModel`

- `var displayAdjustments = DisplayAdjustments.neutral` (observable), loaded from
  / saved to `SessionSettings`.
- On slider change: **throttle** re-renders (coalesce to ~10–15 fps; the trailing
  value always renders) and run the render off-main (`Task.detached` →
  `renderCurrentDisplay` → push the `CGImage` to the live view on `@MainActor`),
  then `saveSettings()`. Throttling prevents a 26MP re-render storm while dragging.

### 5.5 UI

A **"Display Adjustments"** section on the Live tab (or the Setup form's live
group): three labeled sliders bound to `appModel.displayAdjustments`
(Black point 0–0.2, Stretch strength −1…+1, Saturation 0–2) plus a **Reset**
button that sets `.neutral`. Slider release / change triggers the throttled
re-render. Matches existing ControlView idioms (`@Bindable`, `.help()` tooltips).

## 6. Error handling

| Situation | Behavior |
|---|---|
| No stack yet (`currentStack()` nil) | `renderCurrentDisplay` returns nil; live view keeps its last frame; no crash |
| Persisted adjustments out of range | clamped on apply; neutral fields decode to neutral |
| Old settings blob without the key | `decodeIfPresent ?? .neutral` (matches rejection/processor decode) |
| Mono image + saturation ≠ 1 | passthrough (no chroma) |
| Rapid dragging | throttled/coalesced; only the latest value renders |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **Black-point (TDD):** `bp = 0` → output equals the un-clipped stretch input
  path (identity on the clip step); `bp > 0` → linear values below `bp` map to 0
  and the range rescales (assert a known small image: a pixel at `bp` → 0, a
  pixel at 1 → 1, a mid pixel → `(x−bp)/(1−bp)`).
- **Midtone strength (TDD):** `strength = 0` → stretched output byte-identical to
  the existing `stretch(image)` (neutral guarantee); `strength > 0` lowers the
  midpoint (brighter mids), `strength < 0` raises it — assert the MTF midpoint
  moves in the right direction on a known-stats image.
- **Saturation (TDD):** `factor = 1` → identity; `factor = 0` → all channels equal
  the luminance `L` (grey), and `L` is unchanged; `factor = 2` → chroma doubled
  around `L`, clamped to [0,1]; a mono image is returned unchanged.
- **`DisplayAdjustments` Codable:** round-trip equality; an old blob missing the
  key decodes to `.neutral`.
- **`renderCurrentDisplay`:** with a seeded stack, returns a non-nil CGImage; with
  no accumulator, returns nil.
- **Manual/build-verified:** the SwiftUI panel, the throttle, and the off-main
  re-render wiring (window/lifecycle out of unit-test scope, per the prior five
  pillars). RELEASE build must succeed.

## 8. Non-goals (future builds)

Native DBE / gradient extraction (the separate next pillar — this pillar is
uniform global adjustments, not spatial gradient modeling); per-region or masked
adjustments; curves/levels UI; white-point/brightness slider (YAGNI — the three
named cover the want); baking adjustments into `master.fit`; auto-suggesting
adjustment values.

## 9. Risks

| Risk | Mitigation |
|---|---|
| 26MP re-render on every slider tick lags the UI | throttle to ~10–15 fps + off-main render; only the trailing value renders |
| Neutral defaults drift from today's look | explicit byte-identical test at `strength=0, bp=0, sat=1`; neutral is the literal default everywhere |
| Black-point clips faint nebula | capped at 0.2, applied gently; user-controlled and reversible; master stays linear regardless |
| Saturation shifts color balance | luminance-preserving formula keeps `L` fixed; only chroma scales |
| Adjustments leak into the linear master | `master.fit` path never calls `displayCGImage`; a test asserts the master write is unchanged by adjustments |
