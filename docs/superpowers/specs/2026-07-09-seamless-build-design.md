# LiveAstro Studio — "Seamless" Build Design

**Date:** 2026-07-09 · **Status:** approved for planning ·
**Origin:** launch-to-stacking friction found during the 2026-07-08 M8 Seestar shakedown

## 1. Goal

Take LiveAstro from "rebuild-to-release, re-pick every setting, hunt for the
Start button, babysit a feature-less spinner" to **launch → stacking in about
one tap**, self-contained (no shell script), with a window that fits, a
switchable/detachable display, imports that show progress and can be cancelled,
and enough in-app help that a friend who installs the DMG cold can use it.

## 2. Decisions (made 2026-07-09 with Paul)

| Decision | Choice |
|---|---|
| Scope | **All six areas** in one build: window restructure, persist settings, one-tap Seestar Live, import progress+cancel, hover tips, help section |
| Relay | **Native Swift, in-app** — the app watches the mounted `_sub` folder and stage-copies new subs to a local dir (no shell script) |
| Window layout | **Tabbed switch**: one window with a `Live | Setup | Help` segmented control; Detach pops the display to its own OBS-capturable window |
| Help section | A **third tab** rendering a bundled Markdown guide (in-app, no browser) |
| One-tap OBS | One-tap Seestar Live does **NOT** auto-start OBS — it just gets you stacking; OBS stays its own toggle |
| Relay location | App-managed **`~/LiveAstro/relay/<target>-<date>/`** — the user never picks a folder |

## 3. Architecture

```
LiveAstroCore/                                LiveAstroStudio/
  Seestar/
    SeestarRelay.swift   (watch _sub → stage-copy → local dir)
    SeestarDetector.swift(scan /Volumes → newest _sub + target)
  Settings/
    SessionSettings.swift(Codable app settings + UserDefaults store)
  Pipeline/
    SessionPipeline.swift(+ import progress callback + cancel)

  MainView.swift          (Live | Setup | Help tab switch + detach)
  ControlView.swift       (Setup tab: fitted form + fixed Start/End footer)
  BroadcastView.swift     (embedded in Live tab AND the detached window)
  HelpView.swift          (renders bundled Help.md)
  AppModel.swift          (Seestar Live flow, settings load/save, relay lifecycle,
                           import progress state, detach state)
  LiveAstroApp.swift      (main WindowGroup hosts MainView; broadcast Window = detached)
  Resources/Help.md       (bundled help content)
```

### 3.1 Window restructure (§1 tabbed switch + detach)

Today: `WindowGroup("LiveAstro Control"){ControlView}` + a separate
`Window(id:"broadcast"){BroadcastView}` (hidden titlebar — the OBS-captured one).

New:
- The main `WindowGroup` hosts a new **`MainView`** with a top segmented control
  `Live | Setup | Help` (bound to `AppModel.selectedTab`).
  - **Setup** → the existing `ControlView` form, in a `ScrollView`, with **Start/
    End (and Seestar Live) in a fixed footer outside the scroll** so they're
    always visible (fixes the hunt-for-Start problem).
  - **Live** → `BroadcastView` embedded, unless detached (then a "Display detached
    ↗ — click to re-embed" placeholder).
  - **Help** → `HelpView`.
- **Detach** button on the Live tab (and a menu item) calls `openWindow(id:
  "broadcast")` — the existing separate `Window` is the detached mode. It keeps
  `.windowStyle(.hiddenTitleBar)` and the `BroadcastWindowConfigurator`
  ScreenCaptureKit title so **OBS still captures it by name**. `AppModel.isDetached`
  drives the placeholder and prevents double-rendering.
- Default tab: **Setup** at launch; auto-switch to **Live** when a session starts.
- `BroadcastView` is unchanged and reused in both places.

### 3.2 Persist all settings (§2)

```swift
public struct SessionSettings: Codable, Equatable {
    public var sourceMode: SourceMode         // .sirilStacker | .nativeStack
    public var watchFolderPath: String?
    public var filePrefix: String             // "Light_" / "live_stack" / ""
    public var neutralizeBackground: Bool
    public var subExposureSeconds: Double
    public var targetName: String
    public var calibration: CalibrationSelection   // absorbs the existing one
    // OBS settings are NOT duplicated here — they already persist via the OBS
    // build's own UserDefaults keys; SessionSettings coexists with them.
}
public enum SessionSettingsStore {
    static func load(_ d: UserDefaults) -> SessionSettings   // defaults if none
    static func save(_ s: SessionSettings, to d: UserDefaults)
}
```

`AppModel` loads at launch (form pre-fills) and saves whenever a field changes
(or at session start). `CalibrationSelection`/`CalibrationStore` (from the
calibration build) are absorbed as a member rather than duplicated.

### 3.3 One-tap Seestar Live (§3)

**`SeestarRelay`** (LiveAstroCore, testable):
```swift
public final class SeestarRelay {
    public init(source: URL, destination: URL, glob: String = "Light_*_10.0s_*.fit",
                pollSeconds: Double = 5)
    public func start() throws     // background task: stage-copy new matches, skip existing
    public func stop()
    public var onLog: ((String) -> Void)?
    public var relayedCount: Int { get }
}
```
Mirrors the proven `seestar_relay.sh` logic: `mktemp` stage dir, `cp source→stage`,
`cp stage→dest` (atomic-on-local so the watcher never sees a partial FITS), skip
files already in dest, poll every 5 s, clean stop. The `10.0s` glob excludes
prior-night/other-exposure leftovers and survives midnight rollover.

**`SeestarDetector`** (LiveAstroCore):
```swift
public enum SeestarDetector {
    public struct Found { public let subDir: URL; public let target: String; public let subExposure: Double? }
    public static func detect(volumes: URL = URL(fileURLWithPath: "/Volumes")) -> Found?
}
```
Scans `/Volumes/*/MyWorks/*_sub`, picks the **newest-modified** `_sub` as the
active target, derives the target name (strip `_sub`) and parses the exposure
from a sample filename (`…_10.0s_…`).

**Flow — the "Seestar Live" button** (in the Setup footer, primary action):
1. `SeestarDetector.detect()`. If nil → alert with guidance ("Mount the Seestar
   share: Finder → Go → Connect to Server → its smb:// address").
2. Configure: `sourceMode = .nativeStack`, prefix `Light_`, `neutralizeBackground
   = true`, `targetName = found.target`, `subExposureSeconds = found.subExposure ?? 10`.
3. Create `~/LiveAstro/relay/<target>-<yyyy-MM-dd>/`; start `SeestarRelay(source:
   found.subDir, destination: relayDir)`.
4. Start the native session watching `relayDir` (existing pipeline path).
5. Switch to the **Live** tab.
Relay lifecycle is tied to the session: **stop the relay on End Session and on
app quit.** OBS is untouched (its toggle stays independent).

### 3.4 Import progress + cancel (§4)

`SessionPipeline` (import/`importOnce` mode) gains:
```swift
public var onImportProgress: ((_ processed: Int, _ total: Int,
                               _ accepted: Int, _ rejected: Int) -> Void)?
public func cancelImport()   // sets a flag; the consume loop stops draining early
```
`total` = count of matching files in the folder at import start (the source
enumerates it). The consume loop checks the cancel flag and, on cancel, stops
and **finalizes the partial stack** (writes `master.fit` + replay of what
completed) rather than discarding — a clean stop, not a hard abort.

UI (Setup footer, import state): a progress bar + `N / total`, running
**accepted / rejected**, an ETA from the observed rate, and a **Cancel** button.

### 3.5 Hover tips + Help (§5, §6)

- **Hover tips:** `.help("…")` on every meaningful control (source modes, watch
  folder, prefix, neutralize, each calibration row, sub-exposure, Seestar Live,
  Reseed, Detach, Import, OBS fields). Native macOS tooltips — same idea as the
  Seestar's ⓘ popovers.
- **Help tab:** `HelpView` renders a bundled `Resources/Help.md` (via
  `AttributedString(markdown:)`) — sections: what each source mode does, the
  Seestar Live flow, OBS setup (incl. the WebSocket-password gotcha), and quick
  troubleshooting. In-app, no browser.

## 4. Data flow (one-tap Seestar Live)

```
[Seestar Live button]
  → SeestarDetector.detect() → (subDir, target, 10s)
  → SessionSettings updated + saved
  → mkdir ~/LiveAstro/relay/<target>-<date>/
  → SeestarRelay.start(): SMB _sub ──stage-copy──▶ relayDir
  → SessionPipeline(native, watch: relayDir) starts
  → switch to Live tab ──▶ stack builds
[End Session / quit] → SeestarRelay.stop() + pipeline end()
```

## 5. Error handling

| Situation | Behavior |
|---|---|
| No Seestar share mounted | Seestar Live shows guidance alert; nothing starts |
| Multiple `_sub` folders | pick newest-modified (active target); logged |
| Relay source vanishes mid-session (battery dies / unmount) | relay logs + idles, keeps polling; resumes when it remounts (matches the 2026-07-08 auto-resume) |
| SMB partial read | stage-then-local-copy prevents the watcher seeing partials |
| Import cancelled | stop + finalize partial stack (master + replay), never a corrupt session |
| Corrupt settings in UserDefaults | fall back to defaults |
| Detached window closed | Live tab re-embeds automatically |

## 6. Testing

- **`SeestarRelay`** (temp dirs): new matching files copied; existing skipped;
  glob excludes non-`10.0s`; stage-then-copy leaves no partials; `stop()` halts.
- **`SeestarDetector`** (fake `/Volumes` tree): picks newest `_sub`, parses
  target + exposure; returns nil when none.
- **`SessionSettings`**: Codable round-trip through a suite-scoped `UserDefaults`;
  corrupt/missing → defaults.
- **`SessionPipeline` import**: `onImportProgress` reports correct running
  `(processed,total,accepted,rejected)`; `cancelImport()` stops early and
  finalizes a valid partial `master.fit` + replay.
- **UI** (tabs, detach, footer visibility, tooltips, Help render, Seestar Live
  button, import progress/cancel controls): manual validation, documented in the
  README dev section (SwiftUI/window-lifecycle not unit-testable in scope).

## 7. Non-goals (their own future builds)

Multithreading / Accelerate / GPU (the perf ladder); plate-solve / north-up;
the image-quality pillars (winsorized κ-σ, DBE/gradient extraction, noise
reduction); per-frame snapshot-encode speedup during import; controlling the
Seestar over its network protocol (Alpaca closed-loop, v3).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Window restructure breaks OBS capture | detached window keeps hidden-titlebar + `BroadcastWindowConfigurator` title; manual OBS smoke check before merge |
| Relay races the Seestar writing a file | stage-then-local-copy + skip-existing; retry next poll on a failed copy (as the shell relay does) |
| Settings migration from the current no-persist state | first launch after update sees no stored settings → defaults; no migration needed |
| `~/LiveAstro/relay/` growth over many nights | per-target-per-date subdirs; document that they can be deleted; not auto-purged this build |
