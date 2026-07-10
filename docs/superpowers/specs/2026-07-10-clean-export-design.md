# LiveAstro Studio — "Clean Export" Design

**Date:** 2026-07-10 · **Status:** approved for planning ·
**Origin:** LiveAstro → Siril/PixInsight friction found 2026-07-10 while processing the NGC 6960 master (green cast, "No coordinates" plate-solve failure, non-standard FITS-header warning).

## 1. Goal

Make the exported stacked `master.fit` **ecosystem-ready** so the
`LiveAstro → PixInsight/Siril` handoff is frictionless: color-balanced (no OSC
green cast), header-complete (plate solve, SPCC, dark/flat matching all
auto-work), and FITS-standard-compliant (no tool warnings).

## 2. Key insight (settles the design)

The **raw Seestar subs already carry all the metadata**; Clean Export
*propagates* it — no catalog lookup, no network, no user entry. Confirmed by
inspecting a real sub (`Light_NGC 6960_30.0s_LP_...fit`), which contains:

```
OBJECT   = NGC 6960          RA = 314.36667   DEC = 31.834722
FOCALLEN = 160.0             XPIXSZ / YPIXSZ = 2.9
INSTRUME = imx585            TELESCOP = S30 Pro          FILTER = LP
EXPTIME  = 30.0              DATE-OBS = 2026-07-10T03:51:36...  BAYERPAT = GRBG
GAIN = 200   CCD-TEMP = 35.0   SITELAT = 30.5699   SITELONG = -97.6027
```

Today LiveAstro reads a few of these (`BAYERPAT`, `DATE-OBS`) for its own use
but **drops them at master-write time**. The `master.fit` gets a raw,
un-neutralized stack with a minimal, non-standard header. That is the whole bug.

## 3. Decisions (made 2026-07-10 with Paul)

| Decision | Choice |
|---|---|
| Where metadata comes from | **Propagate the source subs' headers** (they already have RA/Dec/focal/pixel/etc.) — not catalog resolution |
| Master color processing | **A — additive neutralization only**: subtract the per-channel skyglow pedestal (kills green), stay honestly linear, leave true color to the user's PixInsight SPCC |
| Display vs saved asymmetry | **Live display** keeps full (additive + multiplicative) neutralization so it looks good on screen; the **saved master** gets additive-only so a subsequent SPCC isn't biased |
| Header writing | Always write the full header (no downside); **color-balance** of the master follows the existing `neutralizeBackground` toggle |
| Bayer pattern | **OMIT `BAYERPAT`** on the RGB (debayered) master — writing it would make tools re-debayer and corrupt color |
| SIMPLE-card warning | Fix by writing **FITS-standard fixed-format cards** (right-justified values) |

## 4. Architecture

Three focused units in `LiveAstroCore`, plus a small manifest bonus.

```
LiveAstroCore/
  FITS/
    FITSWriter.swift        (extend: optional metadata + standard card format)
  Sources/ (frame sources)
    FolderFrameSource.swift (already parses sub headers — retain them)
  Stacking / Pipeline/
    SessionPipeline.swift   (capture first-frame metadata; balance master before write)
  Session/
    SessionModels.swift     (manifest auto-fill from captured header)
```

### 4.1 Source-header capture (unit 1)

Introduce a value type carrying the astro cards we care about:

```swift
public struct SourceMetadata: Equatable {
    public var object: String?
    public var ra: Double?          // degrees
    public var dec: Double?         // degrees
    public var focalLengthMM: Double?
    public var pixelSizeUM: Double?
    public var instrument: String?
    public var telescope: String?
    public var filter: String?
    public var exposureSeconds: Double?
    public var dateObs: String?     // ISO string, verbatim from source
    public var gain: Double?
    public var ccdTempC: Double?
    public var siteLat: Double?
    public var siteLon: Double?
}
```

The frame source already reads FITS headers (`BAYERPAT`, `DATE-OBS`); extend it
to build a `SourceMetadata` from the **first accepted frame** and thread it to
`SessionPipeline.end()`. Any field whose source card is absent stays `nil`
(non-Seestar sources degrade gracefully). Capturing from the *first accepted*
frame gives the session's start `DATE-OBS`, which is the standard choice for a
stack.

### 4.2 Master color-balance (unit 2)

In `SessionPipeline.end()`, before writing `master.fit`:

```swift
let balanced = neutralizeBackground
    ? AutoStretch.neutralizeBackgroundAdditive(master)   // additive-only (choice A)
    : master
let data = FITSWriter.float32(..., pixels: balanced.pixels, metadata: srcMeta, stacking: stackInfo)
```

`neutralizeBackgroundAdditive` already exists (used in the display path). Reuse
it verbatim; do **not** apply the multiplicative `neutralizeBackground` white
balance to the master. The result stays linear (`sourceIsLinear` semantics
unchanged).

### 4.3 Standard-compliant FITS header writer (unit 3)

Extend `FITSWriter.float32(...)` with two optional inputs:
`metadata: SourceMetadata?` and `stacking: StackInfo?` (frame count + total
integration seconds). The writer:

1. **Fixed-format cards** — emit standard FITS cards: the value field
   right-justified so logical `T`/`F` and integers end at column 30, strings
   quoted starting at column 11, per the FITS standard. (The current
   left-justified `"SIMPLE  = T"` is what triggers Siril's
   "SIMPLE card doesn't respect the FITS Standard" warning.)
2. **Structural cards** (unchanged content, fixed format): `SIMPLE, BITPIX,
   NAXIS, NAXIS1/2/3, ROWORDER`.
3. **Propagated cards** (only when the corresponding `metadata` field is
   non-nil): `OBJECT, RA, DEC, FOCALLEN, XPIXSZ, YPIXSZ, INSTRUME, TELESCOP,
   FILTER, EXPTIME, DATE-OBS, GAIN, CCD-TEMP, SITELAT, SITELONG`.
4. **Stacking provenance**: `STACKCNT` (accepted frame count), `TOTALEXP`
   (integration seconds = frames × sub-exposure), and `HISTORY` /`COMMENT`
   cards: `"Stacked N frames — LiveAstro Studio"` and
   `"Background: additive neutralization"` when applied.
5. **No `BAYERPAT`** on the RGB master (channels == 3).
6. Header padded to the 2880-byte block boundary (verify the current padding
   is correct after adding cards).

The old call sites (which pass no metadata) keep working — `metadata`/`stacking`
default to `nil`, producing the same structural header but now in fixed format.

### 4.4 Manifest auto-fill (bonus)

When the user left `camera`/`telescope`/`filter` blank in the form, populate the
`SessionManifest` from the captured `SourceMetadata` (`INSTRUME → camera`,
`TELESCOP → telescope`, `FILTER → filter`). User-entered values always win. This
fixes the empty-`manifest.json` fields with data we already captured.

## 5. Data flow

```
first accepted sub FITS header
  → FolderFrameSource builds SourceMetadata (once, on first accept)
  → SessionPipeline holds it for the session
[End Session / import complete]
  → master = engine.currentStack()
  → balanced = neutralizeBackground ? additive(master) : master
  → FITSWriter.float32(balanced, metadata: srcMeta, stacking: {count, totalExp})
       · fixed-format standard cards
       · propagated OBJECT/RA/DEC/FOCALLEN/XPIXSZ/... (nil-skipped)
       · STACKCNT / TOTALEXP / HISTORY, no BAYERPAT
  → write master.fit
  → manifest camera/telescope/filter filled from srcMeta if form-blank
```

## 6. Error handling

| Situation | Behavior |
|---|---|
| Source subs lack a card (non-Seestar / arbitrary import) | omit that card; write everything else; never fail |
| No `SourceMetadata` captured at all (empty source) | write structural + stacking cards only (still standard-format) |
| `neutralizeBackground` off | write raw linear master (no color-balance) with full header |
| Multi-filter / mixed source in one stack | metadata reflects the **first** accepted frame (documented limitation; matches DATE-OBS convention) |
| RA/Dec present but focal length missing | write RA/Dec anyway (SPCC can still use partial hints) |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **FITSWriter format:** cards are FITS-standard fixed-format (values
  right-justified to column 30 / quoted strings) — assert exact byte layout of
  `SIMPLE`, `BITPIX`, a string card, and an integer card; header length is a
  multiple of 2880.
- **Metadata propagation:** given a `SourceMetadata`, the written header
  contains `OBJECT`, `RA`, `DEC`, `FOCALLEN`, `XPIXSZ`, `EXPTIME`, `DATE-OBS`
  with the right values; **no `BAYERPAT`** for a 3-channel image.
- **Nil-omission:** a `SourceMetadata` with some `nil` fields omits exactly
  those cards and no others.
- **Round-trip:** `FITSReader` reads the writer's output back and recovers the
  metadata cards (extends existing reader tests).
- **Additive balance on master:** a synthetic image with a green pedestal, run
  through the save path with `neutralizeBackground = true`, has its per-channel
  background pedestals equalized (green cast removed) and remains linear; with
  the flag off, the master is byte-identical to the raw stack (same pixels).
- **Header capture:** `FolderFrameSource` builds a `SourceMetadata` matching the
  first sub's header; a source with no astro cards yields an all-nil struct.
- **Manifest auto-fill:** blank form fields get filled from `SourceMetadata`;
  user-entered values are not overwritten.
- **UI:** none required (no UI change — export is automatic on session end).
  Manual validation: export a session, open `master.fit` in Siril → no header
  warning, plate solve resolves from header, no green cast.

## 8. Non-goals (their own future builds)

Catalog resolution / in-app plate solving / WCS `CD`-matrix (SPCC + Siril solve
from RA/Dec + focal length + pixel size, which we now provide); crop-to-overlap;
the pluggable Denoiser/Processor pillar; live background extraction; the perf
ladder; de-Seestar-ify source layer.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Fixed-format card change breaks the reader or old files | round-trip tests; the reader already parses fixed-format (it reads real Seestar/other FITS); change is to the *writer* only |
| Writing wrong RA/Dec convention (deg vs sexagesimal) | source `RA`/`DEC` are already decimal degrees; write them verbatim as `RA`/`DEC` (what the Seestar itself uses and Siril reads) |
| Applying color-balance to the master surprises a user who wanted raw | gated on the existing `neutralizeBackground` toggle; HISTORY card records what was done; additive-only is non-destructive/linear |
| Header padding regression (not a 2880 multiple after adding cards) | explicit test on header length |
