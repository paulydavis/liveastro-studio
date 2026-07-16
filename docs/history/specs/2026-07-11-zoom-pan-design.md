# LiveAstro Studio — "Zoom / Pan" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** Paul's Veil-night request — the Live/Broadcast view shows the whole
frame fit-to-window with no zoom; he wants to zoom in to inspect detail and to
**frame the nebula tightly for the OBS stream**. Pairs with crop-to-overlap
(zoom past ragged edges) and the broadcast path.

## 1. Goal

Zoom and pan the live stack image — in both the embedded Live view and the
detached (OBS-captured) broadcast window — non-destructively. Zooming the
broadcast window frames the stream on the target.

## 2. Core principles

- **Non-destructive, view-only.** Zoom/pan is a pure display transform; the
  stack, `master.fit`, snapshots, and `replay.mp4` stay full-frame.
- **One shared state.** A single `ZoomPanState` on `AppModel` drives both views
  (only one shows the image at a time — the Live tab shows a placeholder when
  detached — so the zoom carries across detach/re-embed with no divergence).
- **Clean stream.** Gestures need no visible chrome; the on-screen controls
  **auto-hide** on the broadcast window so the OBS capture stays clean when
  you're not adjusting.
- **Always covered.** Pan is clamped so the scaled image always fills the view —
  no empty margins ever appear (which would look broken on a stream).
- **Ephemeral.** Zoom state is session-only, not persisted — resets to Fit each
  launch and on a new session start.

## 3. Decisions

| Decision | Choice |
|---|---|
| Scope | Both the embedded Live view and the detached broadcast window; broadcast-window zoom shows in the OBS stream |
| State | One shared `ZoomPanState` on `AppModel` |
| Zoom range | `1×` (Fit, whole frame) … `8×`; slider + Fit + 100% buttons |
| Gestures | Scroll-wheel / trackpad zoom + drag pan — on **both** views, chrome-free |
| Control chrome | Slider + Fit + 100% on **both** views; on the detached broadcast window it **auto-hides** (fades after inactivity, reappears on pointer movement); on the embedded view it stays visible |
| Pan clamp | Image always covers the view; at 1× no pan; when zoomed, pan bounded to the overflow |
| Persistence | None — resets to Fit each launch / new session |

## 4. Architecture

```
LiveAstroCore/
  Imaging/
    ZoomPanState.swift        (NEW: value type + pure clamp math; unit-tested)
LiveAstroStudio/
    AppModel.swift            (+ var zoomPan = ZoomPanState.fit; reset on startSession)
    BroadcastView.swift       (apply scaleEffect+offset; scroll/drag gestures;
                              control overlay with auto-hide on the detached window;
                              Fit/100% buttons + zoom slider)
```

### 4.1 `ZoomPanState` (pure, testable)

```swift
public struct ZoomPanState: Equatable {
    public var scale: CGFloat     // 1.0 = fit; clamped to [1, maxScale]
    public var offset: CGSize     // pan in points, clamped so content covers the view
    public static let maxScale: CGFloat = 8
    public static let fit = ZoomPanState(scale: 1, offset: .zero)
    public init(scale: CGFloat = 1, offset: CGSize = .zero)

    /// Clamp `scale` to [1, maxScale].
    public static func clampScale(_ s: CGFloat) -> CGFloat

    /// Clamp a proposed offset so the scaled content (of `fittedContentSize`,
    /// the size the image occupies at scale 1 inside `viewSize`) still fully
    /// covers `viewSize` at `scale`. Per axis: overflow = max(0, fitted·scale −
    /// view); maxOffset = overflow/2; clamp to ±maxOffset. Empty/zero sizes → .zero.
    public static func clampedOffset(_ proposed: CGSize, scale: CGFloat,
                                     viewSize: CGSize, fittedContentSize: CGSize) -> CGSize
}
```
`fittedContentSize` is the letterboxed size the image occupies at scale 1 under
`scaledToFit` (the view computes it from the image aspect and the view size).
At scale 1 the overflow is ≤ 0 in both axes → offset clamps to `.zero` (no pan).

### 4.2 `AppModel`

```swift
var zoomPan = ZoomPanState.fit
```
Observable; reset to `.fit` in `startSession()` and `startSeestarLive()` (fresh
framing each session). The view mutates it through the clamp helpers.

### 4.3 `BroadcastView`

- Wrap the existing `Image(decorative: cg).resizable().scaledToFit()` with
  `.scaleEffect(model.zoomPan.scale, anchor: .center)` then
  `.offset(model.zoomPan.offset)`, inside the existing `GeometryReader` (so
  `geo.size` = viewSize; compute `fittedContentSize` from the image aspect).
- **Gestures (both views):** a `MagnificationGesture`/scroll handler adjusts
  `scale` (clamped), a `DragGesture` adds to `offset` (re-clamped); on scale
  change, re-clamp offset. (macOS scroll-to-zoom via `.onScroll`-style handling
  or a scroll monitor; trackpad pinch via `MagnificationGesture`.)
- **Controls overlay:** a bottom bar with a zoom `Slider` (1…8), **Fit** (sets
  `.fit`), **100%** (sets scale = imagePixelSize/fittedContentSize, clamped).
  - Embedded (`configuresWindow == false`): overlay always visible.
  - Detached / OBS (`configuresWindow == true`): overlay **auto-hides** — an
    opacity that goes to 0 after ~2.5 s of no pointer activity and back to 1 on
    `.onContinuousHover` movement (a small hide-timer reset). Gestures still work
    while hidden, so the stream stays clean but remains framable live.

## 5. Data flow

```
scroll / pinch → scale' = clampScale(scale ± Δ)
                 offset' = clampedOffset(offset, scale', viewSize, fitted)   // re-clamp on zoom
drag          → offset' = clampedOffset(offset + translation, scale, viewSize, fitted)
slider        → scale' = clampScale(sliderValue); offset re-clamped
Fit button    → zoomPan = .fit
100% button   → scale' = clampScale(imagePixelWidth / fittedContentWidth); offset re-clamped
BroadcastView → Image.scaleEffect(scale).offset(offset)   → embedded + detached(OBS) both reflect it
                (snapshots / replay / master: full-frame, untouched)
```

## 6. Error handling / edge cases

| Situation | Behavior |
|---|---|
| No image yet (`latestImage == nil`) | view shows its existing waiting state; gestures no-op |
| Zero/empty view or content size | `clampedOffset` returns `.zero`; `clampScale` still valid |
| Scale below 1 or above 8 | clamped to `[1, 8]` |
| Zoom out with a large existing pan | offset re-clamped toward center → never pans into empty space |
| Aspect mismatch (portrait Seestar frame in a landscape window) | per-axis clamp: pan allowed only on the axis that overflows |
| New session / launch | `zoomPan` reset to `.fit` |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **`clampScale` (TDD):** 0.3 → 1; 5 → 5; 12 → 8; 1 → 1; 8 → 8.
- **`clampedOffset` at fit (TDD):** scale 1, any proposed offset → `.zero`
  (content fits, no pan) for both matched and letterboxed aspects.
- **`clampedOffset` zoomed (TDD):** scale 2 with a square content in a square
  view — overflow = view; maxOffset = (2·view − view)/2 = view/2; an offset
  beyond that is capped to ±view/2, an in-bounds offset passes unchanged.
- **Per-axis clamp:** a landscape view with portrait content at scale 2 → the
  overflow (and thus allowed pan) differs per axis; assert the narrow axis caps
  tighter.
- **Re-clamp on zoom-out:** a valid offset at scale 4, then scale drops to 1 →
  `clampedOffset` returns `.zero` (previous pan pulled back to center).
- **Degenerate sizes:** zero view or zero content → `.zero`, no divide-by-zero.
- **Manual/build-verified:** the SwiftUI gestures, slider/Fit/100% buttons, the
  `scaleEffect/offset` wiring, and the detached-window auto-hide (out of unit
  scope, per prior pillars). RELEASE build must succeed; the OBS-captured
  broadcast window reflects the zoom; controls auto-hide there and stay visible
  embedded.

## 8. Non-goals (future builds)

Zoom state persistence; double-click / keyboard zoom shortcuts; a pixel-peep
loupe; independent per-view zoom (shared state chosen — only one image-view is
active at a time); zooming the replay/snapshots (they stay full-frame); rotating
the view (north-up is the plate-solve pillar); a mini-map/overview inset.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Empty margins appear on the stream when panned/zoomed | `clampedOffset` guarantees the content always covers the view; a test pins the bounds |
| Control chrome pollutes the OBS capture | auto-hide on the detached (`configuresWindow`) window; gesture-only framing needs no chrome |
| `scaleEffect`+`offset` order/anchor produces jumpy pan | anchor `.center`, offset applied after scale, offset re-clamped on every scale change; validated manually |
| 26MP image scaled 8× is heavy to render | SwiftUI composites the already-decoded `CGImage` on the GPU; no re-decode; same image the view already draws |
| Zoom persists confusingly across sessions | ephemeral by design; reset to Fit on session start and launch |
