# LiveAstro Studio — "Watch Folder Live" (de-Seestar-ify, first slice) Design

**Date:** 2026-07-12 · **Status:** approved for planning ·
**Origin:** Paul's direction that this is NOT a Seestar-centric app — his primary
rig is the **ZWO ASI2600MC-Air** (26MP OSC) on an Askar 120 / AM5N, and the app
should live-stack + broadcast from any source. Today the one-tap live path is
Seestar-bound (`SeestarDetector` scans `/Volumes/*/MyWorks/*_sub`). This slice
makes the one-tap source **generic**: pick the folder your rig writes subs to →
the same session-scoped relay + native stacking the Seestar gets.

## 1. Goal

A source-agnostic **Watch Folder Live** one-tap: point it at any incoming-subs
folder (ASIAIR share / NINA / ASI2600 capture dir), and it relays session-scoped
into a local dir and native-stacks — identical downstream to Seestar Live, with
no Seestar-specific detection. Target + exposure read from the subs' FITS headers.

## 2. Core principles

- **Reuse, don't rebuild.** The native stacker is already source-agnostic; the
  relay + session-scoping (baseline cutoff) + one-tap machinery already exists —
  it's just Seestar-named. This slice generalizes the *source discovery*, not the
  stacking.
- **Pick-the-folder, not auto-detect.** For v1 the user picks the source folder
  (the general path). ASIAIR/NINA share auto-detection is explicitly deferred
  (Paul's note — "auto detect maybe later").
- **Headers over filenames.** Seestar parses target/exposure from its filename
  convention; a generic rig may not. Read target (`OBJECT`) + exposure
  (`EXPTIME`) from the newest sub's FITS header via the existing `SourceMetadata`
  — works for any FITS source. Fall back to the form fields if headers are absent.
- **Seestar Live keeps working.** It becomes *one caller* of the generalized
  relay; behavior unchanged.

## 3. Decisions

| Decision | Choice |
|---|---|
| Scope | Watch Folder Live only (generic session-scoped one-tap on a picked folder); NOT the full pluggable-CaptureSource abstraction |
| ASIAIR auto-detect | **Deferred** (Paul: "auto detect maybe later") — user picks the folder this build |
| Relay | **Rename `SeestarRelay` → `FrameRelay`**, move out of `Seestar/` into a generic `Live/`; it is already source-agnostic. Seestar Live uses `FrameRelay` too |
| Detector | `SeestarDetector` stays Seestar-specific (it IS Seestar detection) |
| Source folder | user-picked (folder picker); Seestar Live still auto-detects its own |
| Target + exposure | from the newest sub's FITS header (`OBJECT`/`EXPTIME`) via `SourceMetadata`; fall back to the form's `targetName`/`subExposureText` |
| Glob | broad FITS match (`*.fit` and `*.fits`) — not exposure-keyed (generic filenames); session-scoping's baseline cutoff handles "only new subs" |
| Downstream | identical to Seestar Live: native-stack mode → `FrameRelay` (session-scoped) → `~/LiveAstro/relay/<target>-<date>/` → `startSession()` → Live tab |

## 4. Architecture

```
LiveAstroCore/
  Live/
    FrameRelay.swift          (RENAMED from Seestar/SeestarRelay.swift — generic)
    LiveSourceMetadata.swift  (NEW: newestFITSMetadata(inFolder:) → target/exposure)
  Seestar/
    SeestarDetector.swift     (unchanged — Seestar-specific detection)
LiveAstroStudio/
    AppModel.swift            (+ startWatchFolderLive(source:); Seestar path uses FrameRelay)
    ControlView.swift         (+ "Watch Folder Live" button → folder pick → startWatchFolderLive)
Tests/LiveAstroCoreTests/
    FrameRelayTests.swift      (RENAMED from SeestarRelayTests; + a *.fit/*.fits glob test)
    LiveSourceMetadataTests.swift (NEW)
```

### 4.1 `FrameRelay` (rename)

Straight rename of `SeestarRelay` (its API is already generic:
`init(source:destination:glob:pollSeconds:sessionScoped:)`, `start()`, `stop()`,
`copyOnce()`, `snapshotBaseline()`, `wildcardMatch`). Move the file to `Live/`,
rename the type, update every reference (`AppModel.seestarRelay` →
`frameRelay`; the Seestar-Live `configureAndStartSeestar`; the tests). No
behavior change — the existing `FrameRelayTests` (renamed) prove it.

### 4.2 `LiveSourceMetadata.newestFITSMetadata(inFolder:)` (new, testable)

```swift
public enum LiveSourceMetadata {
    /// Read the newest .fit/.fits in `folder` and return its target (OBJECT) and
    /// exposure (EXPTIME) from the FITS header. nil if the folder has no FITS or
    /// none parse. Reads only the header (bounded), not the pixels.
    public static func newestFITSMetadata(inFolder folder: URL)
        -> (object: String?, exposureSeconds: Double?)?
}
```
Finds the newest-modified `.fit`/`.fits`, reads its header
(`FITSReader.readHeader`), builds `SourceMetadata(fitsKeywords:)`, returns
`(meta.object, meta.exposureSeconds)`. Header-only read (a bounded prefix is
enough — FITS headers are small 2880-byte blocks) to avoid pulling a 50 MB sub
over SMB just for two keywords.

### 4.3 `AppModel.startWatchFolderLive(source:)`

Mirrors `startSeestarLive` → `configureAndStartSeestar`, but:
- runs off-main to read the newest FITS header (SMB), then hops to `@MainActor`;
- `sourceMode = .nativeStack`, `neutralizeBackground = true`;
- `targetName` = header `OBJECT` ?? the current form value; `subExposureText` =
  header `EXPTIME` ?? the current form value (both stay user-editable);
- `glob` = a broad FITS match (`*.fit`/`*.fits`), NOT exposure-keyed;
- `FrameRelay(source: pickedFolder, destination: ~/LiveAstro/relay/<target>-<date>/, glob:, sessionScoped: true)`;
- `start()` the relay, `watchFolder = relayDir`, `saveSettings()`, `startSession()`,
  rollback on `!isRunning`, `selectedTab = .live`.
- The Seestar `subExposure`/`expToken`-in-folder-name specifics don't apply;
  the relay dir is named `<target>-<date>` (exposure may be unknown/uniform).

### 4.4 UI (`ControlView`)

A **"Watch Folder Live"** button beside "Seestar Live" in the footer. Tapping it
presents a folder picker (`NSOpenPanel`, choose-directory); on selection it calls
`model.startWatchFolderLive(source: url)`. (Optionally remembers the last picked
folder in settings for a true one-tap next time — nice-to-have, not required.)
`.help()`: "Live-stack subs from any folder your rig writes to (ASIAIR / NINA /
ASI camera) — session-scoped from the moment you start."

## 5. Data flow

```
tap Watch Folder Live → pick source folder
  off-main: (object, exposure) = LiveSourceMetadata.newestFITSMetadata(source)   // newest FITS header
  @MainActor: nativeStack; targetName = object ?? form; subExposureText = exposure ?? form
             FrameRelay(source, dest ~/LiveAstro/relay/<target>-<date>, glob "*.fit/*.fits", sessionScoped)
             start relay (baseline cutoff → only subs after tap); watchFolder = relayDir
             startSession() → native stack the relay dir → Live tab
             (snapshots/replay/master as usual)
```

## 6. Error handling / edge cases

| Situation | Behavior |
|---|---|
| Picked folder empty / no FITS yet | metadata nil → use the form's target/exposure; relay waits for subs (baseline empty) |
| Header lacks OBJECT/EXPTIME | that field falls back to the form value |
| Folder unreachable (SMB dropped) | relay logs "source unreachable" (existing); session continues |
| `startSession()` fails | existing rollback: stop relay, clear it, return |
| User cancels the folder picker | no-op |
| Both `.fit` and `.fits` present | both relayed (broad glob covers both extensions) |
| Seestar Live still used | unchanged — now via `FrameRelay` |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **Rename is behavior-preserving:** the renamed `FrameRelayTests` (was
  `SeestarRelayTests`) all pass unchanged in behavior (baseline exclusion,
  session-scope-off copies-all, glob honored, skip-existing).
- **Broad FITS glob (TDD):** `FrameRelay` with a `*.fit`/`*.fits`-style glob
  relays both `X.fit` and `X.fits` subs, still excludes the pre-tap baseline, and
  ignores non-FITS files.
- **`LiveSourceMetadata.newestFITSMetadata` (TDD):** a temp folder with two
  written FITS subs (via `FITSWriter`) whose headers carry `OBJECT`/`EXPTIME`,
  the newer one distinguishable → returns the newest's object + exposure; a
  folder with no FITS → nil; a FITS with no OBJECT/EXPTIME → those fields nil.
- **Manual/build-verified:** `startWatchFolderLive`, the folder-picker button,
  the header→form prefill (SwiftUI/`@MainActor`, per prior pillars); the real
  ASI2600 / ASIAIR round-trip is Paul's manual check. RELEASE build must succeed;
  Seestar Live still works after the rename.

## 8. Non-goals (future builds)

- **ASIAIR / NINA share AUTO-DETECTION** — explicitly deferred (Paul: "auto
  detect maybe later"); revisit as its own slice once the generic path ships.
- The full pluggable `CaptureSource` abstraction (Seestar / ASIAIR / generic
  detectors behind one protocol).
- SMB mount helpers / connect-to-server automation.
- Per-source calibration presets; multi-camera; exposure inference when EXPTIME
  is absent (form value is the fallback).

## 9. Risks

| Risk | Mitigation |
|---|---|
| Rename ripples (missed reference) | mechanical rename with the compiler as the net; the renamed tests must stay green; grep for `SeestarRelay`/`seestarRelay` after |
| Reading a 26MP FITS over SMB just for headers is slow | header-only bounded-prefix read (2880-byte blocks); the relay copies full subs anyway, so one extra header read is negligible |
| A generic folder contains calibration frames (darks/flats) mixed with lights | v1 relays all FITS; the form's file-name-prefix filter remains available; the incoming LIVE folder is normally lights-only — documented, not solved here |
| Exposure unknown (no EXPTIME) → integration badge/relay-dir naming | fall back to the form's sub-exposure; badge already computes from accepted frames × exposure (honest) |
| Confusion between Watch Folder Live and the manual Watch-Folder native mode | Watch Folder Live = one-tap relay+session-scope from a SOURCE folder; the manual mode watches a folder directly. Distinct buttons; documented in `.help()` |
