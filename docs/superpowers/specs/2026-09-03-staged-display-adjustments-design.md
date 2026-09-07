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
| Import mode | Staged model applies, but NO live preview | `AppModel.pipeline` is never set for imports — `ImportController` owns `importPipeline` privately (`ImportController.swift:124`) — so the panel cannot render and `Apply` persists settings without reaching the running import. v1 makes this HONEST (the placeholder reads "Preview available during live sessions") rather than wiring the import pipeline through, which is real plumbing for a mode where `Apply` is ceremony. |

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
   the 26MP stack (cache key below). **Use the EXISTING `AstroImage.downsampled(maxLongEdge:)`**
   (`AstroImage.swift:38`) at `SessionPipeline.previewLongEdge = 1200` (a 26MP 6236x4159 stack
   lands ~1200x800). It is already area-averaging, planar-correct, covered by
   `AstroImageDownsampleTests`, and already used by the render path at `SessionPipeline.swift:928`
   and `:940` for exactly this purpose. **Correction, 2026-09-03:** an earlier draft of this spec
   and its plan specified a NEW `PreviewProxy` component; that was reimplementing shipped code
   and is deleted. Only the named constant and the honesty test below are new.
   The cache key is per source (see "Proxy cache key" below) — clean keys on the published
   master's FreshnessKey, native online on (stack generation, previewStackRevision), watcher
   online on a monotonic token bumped when a frame is retained. Adjustments are
   NOT in the key: the proxy is linear, pre-adjustment, so slider drags reuse it.
4. **Source selector** for blink: `.clean` (`publishedMasterIfCurrent()`) or `.online`, both
   cropped to coverage as the existing paths do, both rendered through the SAME pending
   adjustments. **Correction (2026-09-06, adversarial review + measurement):** identical
   adjustment VALUES do not give an identical TRANSFORM — `AutoStretch` derives shadow/midtone
   from each image's own median and MADN, and `neutralize` scales channels to each image's own
   green median, so the clean and online sides are stretched and balanced independently. The
   comparison therefore does NOT isolate rejection on its own; a global brightness shift rides
   along with it. The confound's direction is conservative (the rejected master has lower MADN
   and stretches harder, so a residual shows MORE, not less), but the flicker is real. Fixed by
   the derive/apply seam below.

### Watcher / external-stacker mode has no engine

`engine` is `private var engine: StackEngine?` (`SessionPipeline.swift:681`) and the WATCHER
init (`:768`, Siril / ASIAIR / any external stacker) never sets it — that path loads each
incoming file directly and renders it (`:1276`). So sourcing `.online` from
`engine.currentStackAndCoverage()` would leave the preview permanently blank in watcher mode,
even though display adjustments apply there exactly as they do natively.

The pipeline therefore retains `lastPreviewLinear: AstroImage?` — the most recent rendered
linear image, ALREADY downsampled to `previewLongEdge` at ingest so the retention costs ~1 MP,
not 26 MP. `.online` resolves to the engine's stack when there is an engine, and to
`lastPreviewLinear` otherwise. A watcher session with no frame yet still yields nil, which the
panel shows as its placeholder.

### Proxy cache key

The key must contain everything that changes the PIXELS, per source:

- `.clean` → the published master's **`FreshnessKey`** (`PublishedMaster.key`). Note the
  behaviour this produces when the key goes stale: `publishedMasterFreshnessKeyIfCurrent()`
  returns nil, so the clean preview DISAPPEARS until a new master publishes — it is never
  rebuilt from the old one. Generation and
  sub count are NOT sufficient: a kappa change, a user reject, a sample-budget change or an
  enable-state transition all produce a different clean master while both of those stay put, so
  a weaker key would serve a stale clean master — and the blink comparison would then be
  comparing against something that no longer exists.
- `.online` → `(engine.currentStackGeneration, previewStackRevision)`.
- watcher `.online` → a monotonic token bumped when a frame is retained. NOT the file digest:
  `StackUpdate.identity` is `FileIdentity?` and `FileIdentity.digest` is `String?`
  (`StackFileWatcher.swift:150,14`), so a digest key needs a double unwrap and a nil fallback,
  while the token is always correct and costs nothing (the retained image is downsampled at
  ingest, so a "rebuild" just hands back the stored image).

`previewStackRevision` is a new lock-guarded monotonic counter bumped at ALL THREE
`processedCount += 1` sites (`SessionPipeline.swift:890`, `:970`, `:1164`). The third is the
NATIVE LIVE path — missing it freezes a live session's preview, since `onUpdate` keeps
requesting refreshes while the key never moves. It exists because `processedCount` (`:164`) is a private var mutated on the consume
task (`:890`, `:970`); reading it from a preview render — which runs on a detached task — would
be a data race.

Adjustments remain deliberately absent from the key: the proxy is linear and pre-adjustment, so
slider drags reuse it.

The cache holds one slot PER SOURCE. Hold-to-compare alternates clean -> online -> clean, so a
single-slot cache would evict and rebuild from the full-resolution stack on every press and every
release — making the one interaction that must feel instant the most expensive in the panel.

North-up needs no work: it is applied inside `displayCGImage` from `currentWCS`, so the
preview inherits it.

### Preview lifecycle

The preview is pinned on screen, so anything that changes what it SHOULD show must refresh it,
or it sits stale — at worst showing the previous session's stack until a control is touched.
Refresh on: the `onUpdate` callback (a new sub changed the stack); session start once the
pipeline is wired; a user reject and any live-rejection config change (both invalidate the
published master immediately, so the preview must drop back to online rather than keep showing a
clean master that is no longer served); and a new `onCleanMasterPublished` callback, fired by `publishRefineResult`
(outside `regLock`) after it installs a servable master. That callback is required rather than
cosmetic: `AppModel.liveRejectionStatus` is a COMPUTED property with no change notification, so
there is no transition to observe and the panel would otherwise keep showing the online master
after the first clean one publishes. It fires from the refiner's background pass, so the
`AppModel` side hops to the main actor the way the other callbacks do (`AppModel.swift:923`). Clear `previewImage`
at session start and session end. Reseeds are NOT covered by `onUpdate`: a manual reseed changes the stack immediately and may
not be followed by an accepted frame for some time, leaving the panel on the old stack. Refresh
from `onSolveStateChanged`, which already fires on that edge (`SessionPipeline.swift:211`) and
also on solve ARRIVAL (`:265`) — the latter matters because North-up is applied inside
`displayCGImage`, so the preview's orientation changes when a solve lands.

### Render ordering

Preview renders run on detached tasks, so a slow earlier render can finish after a newer one and
overwrite the preview with a stale image. Each request carries a monotonic stamp and only the
newest may publish.

Slider drags are throttled to ~12 fps, but DISCRETE actions — Revert, Reset, blink press and
release, new frames, session boundaries — bypass the throttle. A swallowed blink release is the
dangerous case: it would strand the panel on the online master while the operator believed they
were seeing the clean one, actively misrepresenting the thing the comparison exists to show.

### UI (DisplaySettingsView)

- Every control fires `refreshPreview()` from an `.onChange` on its own field, NOT from
  `onEditingChanged`. The existing sliders use `{ editing in if !editing { ... } }`, which fires
  only on RELEASE — that is why the app has no live feedback while dragging today, and reusing it
  would give a preview panel that barely moves.
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

## Measured: what downsampling actually costs (2026-09-06)

Downsampling destroys most of the MADN (noise averages away), so the preview's derived stretch is
not identical to the broadcast's. Measured on Paul's real data rather than a fixture:

| case | MADN change | 8-bit preview-vs-broadcast error |
|---|---|---|
| 16-sub master (deep) | -69% | 0.10/255 max |
| single raw sub (noisiest real case) | -91.5% | 1.76/255 max, 1.44 mean |

The error scales with MADN/median: `shadow = median - 2.8*MADN`, and on real astro frames MADN is
10-130x smaller than the median, so the shadow point barely moves. An adversarial review measured
7.4/255 and ~19/255 on synthetic fixtures whose noise-to-signal ratio is far above what this camera
produces. NOTE the same weakness in our OWN honesty test: `PreviewTestSupport.starField` has a low
MADN/median ratio, which is why it measured 0.007%. It measures the right quantity on an
unrepresentative image and needs a noisy fixture added.

### The derive/apply seam (fixes both this and the blink flicker)

Split `AutoStretch` into `parameters(for:)` and `apply(_:params:)`, keeping
`stretch()` == `apply(image, parameters(for: image))` so every existing caller — including the
golden-hash path feeding the broadcast — stays byte-identical. Then: derive parameters from the
FULL-RES linear image and apply them to the proxy (preview matches broadcast exactly), and derive
ONCE for both blink sides (no flicker). `neutralize` is image-derived too and needs the same
treatment or colour will still shift.

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
