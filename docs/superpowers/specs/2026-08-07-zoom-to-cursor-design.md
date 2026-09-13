# Zoom Toward Cursor — Design

**Goal:** make the existing live-view zoom magnify toward the pointer instead of the
frame center, so the operator can zoom straight into an off-center region (e.g. framing
M16 at the edge of an M17 field) without zooming the middle and then pan-hunting.

**Scope:** an enhancement to the shipped zoom/pan feature (`ZoomPanState` +
`BroadcastView`). No new UI, no behavior change to Fit / 100% / slider / pan / clamp.

## Background (current behavior)

The image renders `.scaledToFit()` then `.scaleEffect(scale, anchor: .center)` then
`.offset(offset)`. Scroll-wheel, pinch, and slider all change `scale` about the view
center; `offset` is manual pan, clamped by `ZoomPanState.clampedOffset` so the scaled
content always covers the view. Because scaling is center-anchored, zooming keeps the
center fixed — an off-center target drifts and must be re-panned.

## Change

### 1. Pure math (`ZoomPanState`)

Add a pure, testable function that changes scale while holding a chosen view point fixed:

```
static func zoomed(toScale newScale: CGFloat,
                   about pointInView: CGPoint,       // cursor in view coords (origin top-left)
                   viewSize: CGSize,
                   from current: ZoomPanState,
                   fittedContentSize: CGSize) -> ZoomPanState
```

Math (anchor point stays under the cursor):
- Let `P = (pointInView − viewCenter)` where `viewCenter = (viewSize/2)`. `P` is the
  cursor relative to the center, matching the `.scaleEffect(anchor: .center)` frame.
- New scale `s1 = clampScale(newScale)`, old scale `s0 = current.scale`.
- `offset1 = P − (P − current.offset) * (s1 / s0)`.
- Return `ZoomPanState(scale: s1, offset: clampedOffset(offset1, scale: s1, viewSize:, fittedContentSize:))`.

Properties (become the tests):
- When `P == 0` (cursor at center), `offset1 == current.offset * (s1/s0)`:
  the content point at the view centre stays fixed. This differs from the unchanged
  slider's direct scale write when an existing pan is nonzero.
- With no clamping active, the content point under the cursor before the zoom is under
  the cursor after (target stays put).
- `s0 == 0` guard (shouldn't occur; scale ≥ 1) returns `current` unchanged.
- Degenerate `viewSize` or non-positive starting scale → return `current`.
  Degenerate fitted content size clamps the resulting offset to `.zero`.

### 2. Wiring (`BroadcastView`)

- **Scroll wheel** (`ScrollWheelZoom` `NSViewRepresentable`): it already receives the
  `NSEvent`; convert `locationInWindow` → the representable's view coords (flip y to
  top-left origin to match SwiftUI) and call `zoomed(about: thatPoint)` with
  `newScale = current.scale * zoomFactor(from: event.scrollingDeltaY)`. Replaces the
  current center-anchored scale write.
- **Pinch** (`MagnificationGesture`): `MagnificationGesture` gives no
  location, so anchor at the **last hover point**. Track it: `@State var lastHoverInView:
  CGPoint?` set from the existing `.onContinuousHover` (it already fires for the
  controls auto-hide). Pinch calls `zoomed(about: lastHoverInView ?? viewCenter)`.
  Clear the hover point on `.ended`; absent hover uses the view centre.
- **Slider / Fit / 100% / drag-pan**: unchanged. Slider scale changes remain
  centre-anchored with the existing offset re-clamp; a slider interaction has no
  pointer location on the image to preserve.
- Both fitting and rendering use the resolved display image: the detached OBS
  window consumes `broadcastImage`, while the embedded view consumes `latestImage`.

## Testing

- `ZoomPanStateTests`: center-point reduces to center-anchor; off-center
  point keeps the target content-point stationary (unclamped regime); clamp still holds
  (offset within ±maxOffset); zoom-out toward a corner re-centers toward `.fit` as scale
  → 1; degenerate sizes/`s0` guarded.
- Existing `ZoomPanState` and BroadcastView tests remain green; gesture wiring is
  manual-verified on next launch (scroll over M16 zooms into M16).

## Non-goals

No zoom-to-cursor for the drag-pan (pan is already free positioning); no marquee/box
zoom; no persistence; no change to the clamp policy (content still covers the view — a
zoomed-in target near an edge stops at the frame edge, which is correct for broadcast).
