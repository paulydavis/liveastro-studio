# Staged Display Adjustments + Preview Panel — Design

**Status:** approved in brainstorm 2026-09-03, awaiting spec review
**Branch:** `feature/staged-display-adjustments` (from main @ v3.6.1)

## Goal

Let Paul tune display adjustments mid-broadcast without every slider drag reaching the
audience, by previewing pending changes in a panel beside the controls and committing them
explicitly. Fold in the clean-vs-online blink comparison, which shares that panel.

## Problem

`AppModel.applyDisplayAdjustments()` (`AppModel.swift:531`) persists, pushes to
`SessionPipeline.displayAdjustments`, and re-renders — all on every slider tick. Since the
pipeline's adjustments feed the broadcast, snapshots, `latest.png` and replay, every
exploratory drag is published live. Paul tunes mid-stream often, so viewers see the
intermediate states.

Secondary problem: there is no way to see whether live trail-rejection is helping. Measuring
it (2026-09-03) took five separate analyses; a hold-to-compare toggle answers it visually in
one second. See `project-liveastro-trail-rejection-measured` in memory.

## Decisions taken (with rationale)

| Decision | Chosen | Why |
|---|---|---|
| Commit model | Explicit **Apply / Revert** | Paul tunes mid-stream often; he needs to explore through ugly intermediate states and publish once. |
| Preview content | **Whole-frame downsampled**, no 1:1 crop in v1 | See "Why not a crop" below — a crop would misrepresent the two most-used controls. |
| Main display view | Shows **committed** | The big view stays ground truth for what the audience sees; the panel is the workbench. |
| Blink interaction | **Press-and-hold** | The transition is what makes a faint trail pop; needs no mode, timer, or extra state. |
| Import mode | Same staged model | One behaviour for one panel; `Apply` is ceremony there, but two modes would be worse. |

## Why not a 1:1 crop (the non-obvious constraint)

An earlier informal recommendation favoured a 1:1 crop as "more useful and cheaper". Reading
the imaging code disproved it:

- `AutoStretch` derives its transform from the image's OWN median and MADN
  (`AutoStretch.swift:47-57`). A crop's statistics differ from the full frame, so a crop
  preview shows a DIFFERENT stretch than the broadcast receives.
- `BackgroundExtraction.flattenMultiscale` computes
  `scaleRadius = (scale/100) * max(sw, sh)` (`BackgroundExtraction.swift:281`) — DBE's scale
  is RELATIVE TO IMAGE DIMENSIONS, so the same slider value means a different physical radius
  on a crop.

Downsampling preserves both properties (uniform sampling preserves the statistics; relative
geometry preserves the radius), so a downsampled whole frame is faithful where a crop is not.
Denoise is the one genuinely local control and is the only thing a crop would serve better;
it is judged in the main view for v1. A crop remains possible later but requires splitting
"derive transform from whole frame" from "apply transform to this region".

## Pixel layout (non-negotiable)

`AstroImage` is **planar / channel-major** — `AstroImage.swift:16`, and see `Denoiser.swift:78`
indexing `sane[i], sane[plane + i], sane[2 * plane + i]`. Index as `c * plane + y * width + x`.
Interleaved `(y * width + x) * channels + c` indexing silently scrambles colour, and — as caught
in review — will do so INVISIBLY if a test helper repeats the same mistake, since the helper and
the implementation then agree with each other. Preview tests therefore include a colour-plane
sentinel that fails under interleaved indexing.

## Architecture

### State (LiveAstroCore: `StagedAdjustments`)

**Amended 2026-09-03 during planning:** `LiveAstroStudio` is an `executableTarget` with NO
test target (see `Package.swift:12,18`) — only `LiveAstroCore` is unit-testable. Putting this
state in `AppModel` would make the staging invariant (test 2), the property the whole feature
rests on, testable only by another source-text grep — the very debt this spec criticises. So
the state machine is a pure value type in `LiveAstroCore`:
`StagedAdjustments { committed, pending, hasPendingChanges, mutating apply() -> DisplayAdjustments, mutating revert() }`.
`AppModel` owns one instance and forwards; all staging logic is unit-tested in
`LiveAstroCoreTests`.

- `committed` — held by `SessionPipeline`; feeds broadcast, snapshots,
  `latest.png`, replay, `master.fit`. Written ONLY by Apply. The only one persisted to
  `SessionSettingsStore`.
- `pending` — bound to the sliders. Never reaches `SessionPipeline`, never
  persisted, discarded on session end.
- `hasPendingChanges` = `pending != committed`, drives the panel's pending treatment and the
  enabled state of Apply/Revert.

`apply()` sets `committed = pending` and RETURNS the new committed value; `AppModel` pushes it
to the pipeline, persists, and refreshes the main view. `revert()` sets `pending = committed`.

### Render seam (SessionPipeline)

1. `displayCGImage(from:adjustments:)` — currently reads the stored property
   (`SessionPipeline.swift:1075`); becomes a pure function of (image, adjustments). Existing
   callers pass the committed value; behaviour unchanged.
2. `renderPreview(source:adjustments:) -> CGImage?` — NON-mutating. The existing
   `renderCurrentDisplay(adjustments:)` commits as a side effect (`:1116`) and is retained
   only for the Apply path.
3. **Downsampled proxy** — the preview renders from a cached, downsampled linear image, not
   the 26MP stack. **Use the EXISTING `AstroImage.downsampled(maxLongEdge:)`**
   (`AstroImage.swift:38`) at `SessionPipeline.previewLongEdge = 1200` (a 26MP 6236x4159 stack
   lands ~1200x800). It is already area-averaging, planar-correct, covered by
   `AstroImageDownsampleTests`, and already used by the render path at `SessionPipeline.swift:928`
   and `:940` for exactly this purpose. **Correction, 2026-09-03:** an earlier draft of this spec
   and its plan specified a NEW `PreviewProxy` component; that was reimplementing shipped code
   and is deleted. Only the named constant and the honesty test below are new.
   The cache key is (stack generation, processed sub count, source selector) — i.e. it is
   invalidated by a new sub, a reseed, or switching between clean and online. Adjustments are
   NOT in the key: the proxy is linear, pre-adjustment, so slider drags reuse it.
4. **Source selector** for blink: `.clean` (`publishedMasterIfCurrent()`) or `.online`
   (`engine.currentStackAndCoverage()`), both cropped to coverage as the existing paths do,
   both rendered through the SAME pending adjustments so the comparison isolates rejection.

North-up needs no work: it is applied inside `displayCGImage` from `currentWCS`, so the
preview inherits it.

### Preview lifecycle

The preview is pinned on screen, so anything that changes what it SHOULD show must refresh it,
or it sits stale — at worst showing the previous session's stack until a control is touched.
Refresh on: the `onUpdate` callback (a new sub changed the stack); session start once the
pipeline is wired; and the transition of `liveRejectionStatus` to `.active`, when the first
clean master publishes and the preview source flips from online to clean. Clear `previewImage`
at session start and session end. Reseeds and source changes are covered by `onUpdate` plus the
proxy cache key, which includes the stack generation.

### Render ordering

Preview renders run on detached tasks, so a slow earlier render can finish after a newer one and
overwrite the preview with a stale image. Each request carries a monotonic stamp and only the
newest may publish.

Slider drags are throttled to ~12 fps, but DISCRETE actions — Revert, Reset, blink press and
release, new frames, session boundaries — bypass the throttle. A swallowed blink release is the
dangerous case: it would strand the panel on the online master while the operator believed they
were seeing the clean one, actively misrepresenting the thing the comparison exists to show.

### UI (DisplaySettingsView)

- Preview PINNED at the top of the tab, controls scroll beneath — otherwise the DBE and
  denoise sliders push the preview off-screen exactly when in use.
- Apply / Revert beside the preview, disabled while pending == committed.
- Hold-to-compare button beneath the preview. Disabled state explains itself by reusing
  `LiveRejectionStatus` (`.off(reason:)` / `.building(subs:)` / `.active(subs:)`) from
  v3.6.0 — "turned off", "network source", "building over 7 subs…".
- Placeholder before a stack exists.
- **Reset** (`DisplaySettingsView.swift:108`) stages `.liveDefault` as a PENDING edit and
  refreshes the preview. It must not write through to the broadcast, or it would be the single
  control that bypasses staging.

## Testing

1. **Broadcast parity (highest risk).** The `displayCGImage` signature change touches the path
   producing broadcast, snapshots, `latest.png` and `master.fit`. Assert renders through the
   committed path are byte-identical to pre-change output.
2. **Staging invariant.** With pending != committed, `pipeline.displayAdjustments == committed`.
3. **Preview honesty.** Assert the stretch parameters AutoStretch DERIVES (median, MADN) from
   the downsampled proxy match those from the full frame to within 2% relative, on a real
   stacked frame rather than a synthetic flat one (a constant image makes this test vacuous —
   every statistic survives any sampling). Deliberately not a pixel comparison, which would
   need an arbitrary tolerance and prove little. The existing area-averaging downsample should
   sit far inside 2%; if it does not, the sampling is wrong and the preview is lying.
   A colour-plane sentinel accompanies it: three channels of distinct constants must survive the
   downsample separately, which fails under interleaved indexing.
4. Apply commits + persists; Revert discards.
5. Main view follows committed while pending differs.
6. Blink renders both sources through identical adjustments.
7. Disabled states map correctly from `LiveRejectionStatus`.

## Debt this disturbs

`AppSourceRegressionTests.swift:45`
(`testAppModelPushesDisplayAdjustmentsToPipelineIndependentOfRenderThrottle`) asserts on
SOURCE TEXT — it greps `AppModel.swift` for `"p.displayAdjustments = displayAdjustments"`.
Restructuring that method will either break it or let it pass while the behaviour it names has
changed. Replace it with a behavioural test as part of this work.

## Risks

- Behaviour change to a shipped app in the most-touched panel; it will feel different from
  v3.6.1 on day one. Instant feedback now costs two clicks.
- The parity risk above is silent if untested — it lands in recorded data, not in a crash.

## Out of scope (v1)

1:1 crop preview; automatic/timed blink; per-region preview picking; staged-only-in-live-mode.
