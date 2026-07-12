# ASIAIR Live — one-tap auto-detect — Design

**Date:** 2026-07-12
**Branch:** `feature/asiair-live` (off `main` @ 0447c2f)
**Status:** approved for planning

## Problem

LiveAstro Studio has two one-tap live sources — **Seestar Live** (auto-detects the Seestar SMB share) and **Watch Folder Live** (user picks the folder). Paul's *primary* rig is the ASI2600MC-Air on an ASIAIR, which writes subs to a predictable SMB path (`/Volumes/ASIAIR/Autorun/Light/<TARGET>/`). Today the ASIAIR path only works through Watch Folder Live's manual folder pick. This pillar makes the ASIAIR a first-class one-tap source with true auto-detection — the next "de-Seestar-ify" slice.

## Goals

1. A one-tap **ASIAIR Live** button that auto-detects tonight's ASIAIR target folder and starts session-scoped relay + native stacking — no folder picking.
2. Reuse the *entire* shipped machinery (`FrameRelay` session-scoped baseline cutoff, native stacking pipeline). Do not rebuild relay or stacking.
3. Seestar Live and Watch Folder Live remain unchanged and working.

## Non-Goals

- No generic pluggable `CaptureSource`/detector protocol unifying Seestar+ASIAIR behind one button — that is the deferred later pillar.
- v1 covers **Autorun/Light only** (the documented path Paul shoots with). No ASIAIR Plan-mode or manual-capture folders.
- No ASIAIR-specific filename parsing — exposure comes from the FITS header.
- No new networking / SMB mounting in-app; the user mounts the share (as with Seestar).

## Architecture

Structurally parallel to Seestar Live: a Core detector finds the target folder; an AppModel one-tap wires it into the existing relay + stacking path.

### 1. Detector — `Sources/LiveAstroCore/ASIAIR/ASIAIRDetector.swift` (NEW, Foundation-only, unit-tested)

```swift
public enum ASIAIRDetector {
    public struct Found: Equatable {
        public let subDir: URL
        public let target: String
        public let subExposure: Double?
        public init(subDir: URL, target: String, subExposure: Double?)
    }

    /// Scan <volumesRoot>/*/Autorun/Light/<TARGET>/ and return the newest-modified
    /// target folder that contains at least one .fit/.fits sub. `target` is the
    /// folder name; `subExposure` is read from the newest FITS header (EXPTIME).
    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found?
}
```

**Detection rules (mirrors `SeestarDetector`, different path):**
- For each volume under `volumesRoot`, look at `<vol>/Autorun/Light/`. Enumerate its immediate subdirectories (the per-target folders).
- Keep only target folders that contain ≥1 file with extension `fit`/`fits` (case-insensitive) — this "must contain FITS" guard prevents selecting an empty leftover target folder. (`SeestarDetector` does not need this guard because its `_sub` suffix already marks capture folders; ASIAIR target folders have no marker, so containment is the signal.)
- Among the qualifying folders, pick the one with the newest `contentModificationDate` (tonight's target). Ties/absent dates resolve to `.distantPast`, same as `SeestarDetector`.
- `target` = the folder's `lastPathComponent`.
- `subExposure` = `LiveSourceMetadata.newestFITSMetadata(inFolder: subDir)?.exposureSeconds` — bounded FITS-header read of EXPTIME; no ASIAIR filename convention assumed.
- Returns `nil` when no volume has `Autorun/Light/`, or no target folder contains FITS.

`ASIAIRDetector` depends only on Foundation + the existing `LiveSourceMetadata`. It does not read pixel data.

### 2. AppModel wiring — `startASIAIRLive()` + `configureAndStartASIAIR(_:)` (NEW methods in `Sources/LiveAstroStudio/AppModel.swift`)

Mirror the Seestar pair (`startSeestarLive` / `configureAndStartSeestar`):

```swift
func startASIAIRLive() {
    guard !isRunning, !isImporting, !isDetecting else { return }
    zoomPan = .fit
    isDetecting = true
    log.append("Looking for ASIAIR share…")
    Task.detached { [weak self] in
        let found = ASIAIRDetector.detect()          // SMB directory work, off main
        await MainActor.run {
            guard let self else { return }
            self.isDetecting = false
            guard let found else {
                self.errorMessage = "No ASIAIR share found. In the ASIAIR app: Settings → Network Share → Enable. Then on the Mac: Finder → Go → Connect to Server → smb://asiair.local, and try again."
                return
            }
            self.configureAndStartASIAIR(found)
        }
    }
}
```

`configureAndStartASIAIR(_:)` mirrors `configureAndStartSeestar` with two differences:
- **Glob:** the ASIAIR target folder is already target-scoped, so relay every FITS in it rather than matching an exposure token. Build the glob from the detected file extension: read `LiveSourceMetadata.newestFITSMetadata(inFolder: found.subDir)?.fileExtension` (default `"fit"`), glob = `"*.<ext>"`. (Contrast Seestar's `Light_*_<exp>s_*.fit`.)
- Everything else identical: `sourceMode = .nativeStack`, `neutralizeBackground = true`, `targetName = found.target`, `subExposureText` from `found.subExposure` (default 10), relay dir `~/LiveAstro/relay/<target>-<date>[-<exp>s]/`, `FrameRelay(source: found.subDir, destination: relayDir, glob:)` (session-scoped baseline cutoff is the `FrameRelay` default), `relay.start()`, `startSession()`, undo-on-failure, `selectedTab = .live`.
- `fileNamePrefix`: ASIAIR light files are not guaranteed to start with `Light_`; since the glob is `*.<ext>` (not prefix-based) the relay does not depend on the prefix. Set `fileNamePrefix = ""` (the native stacker keys off the relay folder, not the prefix) — matching how Watch Folder Live configures a generic folder. (Confirm against `configureAndStartWatchFolder` during implementation and mirror whatever it sets.)

`endSession()` already stops `frameRelay` unconditionally — no change needed.

### 3. UI + naming — `Sources/LiveAstroStudio/ControlView.swift`

The three one-tap live-source buttons all currently end in "Live" (repetitive) and "Watch Folder Live" is clunky. Adopt a **verb-led** naming scheme across all three — the buttons *start* a live session, so lead with the verb; the auto-detect sources use "Start", the manual pick uses "Choose…" (ellipsis signals a picker opens first):

| Action | Current label (line) | New label |
|---|---|---|
| Auto-detect Seestar (`startSeestarLive`) | `"Seestar Live"` (ControlView.swift:155) | **`Start Seestar`** |
| Auto-detect ASIAIR (`startASIAIRLive`) | — (new) | **`Start ASIAIR`** |
| Manual folder pick (`pickWatchFolderLive`) | `"Watch Folder Live"` (ControlView.swift:158) | **`Choose Folder…`** |

- Add the new **Start ASIAIR** button between Start Seestar and Choose Folder…, calling `model.startASIAIRLive()`, with the same `.disabled(model.isRunning || model.isImporting || model.isDetecting)` idiom (match whatever guard the sibling buttons use) and a `.help("Auto-detect the ASIAIR's Autorun/Light folder, relay its subs, and begin native stacking — one tap.")`.
- Rename the two existing buttons' labels to the New labels above. Behavior/handlers unchanged — labels only. Keep each button's existing `.help(...)` tooltip text (still accurate).
- The `Choose Folder…` live button sits in the footer one-tap row; it is distinct from the pre-existing `Choose…` sub-control in the Raw-subs watch-folder config section (ControlView.swift:30), which is unchanged.

### 4. Help.md label consistency — `Sources/LiveAstroStudio/Resources/Help.md`

Update the six references to the old button names so the docs match the new labels (the app just shipped with "Seestar Live"/"Watch Folder Live" wording):
- "Seestar Live" → "Start Seestar" where it names the *button* (Quick Start step, Source Modes table row label, and the Troubleshooting `"No share found" when tapping Start Seestar` heading + body).
- "Watch Folder Live" → "Choose Folder…" where it names the *button* (Quick Start step, Source Modes table row, Troubleshooting heading).
- Keep prose that refers to the *concept* readable (e.g. "the folder your rig writes subs to"); only the button-name tokens change. Content must stay within the markdown subset the renderer supports (no new constructs).

## Error Handling

- **No share / no FITS:** `detect()` → nil → `errorMessage` guidance (mount instructions). No crash.
- **Relay start failure:** `errorMessage = "Relay failed to start: …"`, no session started (mirror Seestar).
- **Detected folder but no readable exposure:** `subExposure` nil → `subExposureText` defaults to 10 and glob falls back to `"*.fit"` — session still starts.
- All directory I/O uses `try?`/optional handling (mirrors `SeestarDetector` / `LiveSourceMetadata`); a permission error on one volume must not abort the scan of others.

## Testing

**Detector (TDD, `Tests/LiveAstroCoreTests/ASIAIRDetectorTests.swift`):** temp `/Volumes`-like tree, mirroring `SeestarDetectorTests` + `LiveSourceMetadataTests` fixture helpers:
- `testDetectPicksNewestTargetFolder` — two targets under `<vol>/Autorun/Light/`, assert newest-modified wins; `target` = folder name; `subDir.lastPathComponent` correct.
- `testTargetFromFolderName` — target string equals the folder's name (with spaces, e.g. `"NGC 7000"`).
- `testExposureFromFITSHeader` — write a FITS with `EXPTIME` via `FITSWriter.float32(..., metadata:)` (as `LiveSourceMetadataTests.writeFITS` does); assert `subExposure` matches the header.
- `testIgnoresTargetFolderWithoutFITS` — an empty target folder is not selected; a sibling with FITS is.
- `testReturnsNilWhenNoAutorunLight` — a volume without `Autorun/Light/` yields nil.
- `testReturnsNilWhenNoFITSAnywhere` — `Autorun/Light/<target>/` exists but contains only non-FITS.
- `testScansMultipleVolumes` — the qualifying folder on a second volume is found.
- `testFitsExtensionSupported` — a target whose subs are `.fits` (not `.fit`) is detected.

**AppModel + UI:** build/manual-verified RELEASE (SwiftUI/@Observable, no unit test — house pattern). Manual: mount ASIAIR share (or a fake `/Volumes/ASIAIR/Autorun/Light/<target>/` tree), tap ASIAIR Live, confirm detect → relay → live stack; tap with no share → guidance message.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `ASIAIRDetector` uses Foundation only (+ the in-module `LiveSourceMetadata`, `FITSReader`).
- Zero external dependencies.
- Core logic is TDD'd (`swift test --filter LiveAstroCoreTests`); SwiftUI app code is build/manual-verified.
- New source group `Sources/LiveAstroCore/ASIAIR/`.
- Seestar Live and Watch Folder Live behavior unchanged.
- Co-Authored-By Claude trailer allowed in this repo.

## Task Order (for the plan)

1. **T1 — `ASIAIRDetector` (TDD).** Detector + all detector tests. The shared interface the AppModel consumes.
2. **T2 — AppModel wiring + ControlView button + verb-led rename + Help.md consistency (build/manual-verified).** Depends on T1's `Found` type. Adds `startASIAIRLive`/`configureAndStartASIAIR` (detect → relay → stacking), adds the **Start ASIAIR** button, renames the two existing buttons to **Start Seestar** / **Choose Folder…**, and updates the six Help.md button-name references to match. All build/manual-verified (SwiftUI + docs). Keep the change label-only for the existing buttons — no handler/behavior changes.
