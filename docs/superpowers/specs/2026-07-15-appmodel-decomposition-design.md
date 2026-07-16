# AppModel Decomposition — Design

**Date:** 2026-07-15
**Branch:** `feature/appmodel-decomposition` (off `main` @ 1f57953)
**Status:** approved for planning
**Stabilization step 4 of 6.**

## Problem

`AppModel` is an 891-line `@MainActor @Observable` coordination hub: OBS/broadcast/scene automation (~250 lines, self-contained state), live-source orchestration (relay + 3 detect paths, ~150), session lifecycle (~180), import (~75), post-processing (~55), settings (~50), plus cross-cutting UI state (`log`, `errorMessage`, `isRunning/isImporting/isDetecting`) written by everything. It is the app's largest file, the hardest to review, and the concentration point of the remaining Swift 6 distance.

## Goal

**Staged full decomposition, zero behavior change.** Extract three controllers in risk order — Broadcast, LiveSource, Import — each an independently shippable stage gated by the full suite; what remains in `AppModel` is its right size (~350–400 lines: session lifecycle, settings, shared UI state, controller ownership). Same public behavior, same settings blobs, same log lines, same UI.

## Approach (chosen: staged full decomposition — "B with a seatbelt")

Each stage: move code verbatim where possible → wire seams → re-point views → full `swift test` + release build green → commit. Each stage is individually revertable. No stage changes logic; renames and access-level adjustments only as required by the move.

## Architecture

### Ownership and observation
`AppModel` owns the controllers as `let` stored properties; each controller is its own `@MainActor @Observable final class`. SwiftUI observation composes: views read `model.broadcast.streamHealth` etc. and re-render on the controller's changes. Views keep receiving only `AppModel` via the environment — controller access is through `model.<controller>` (no new environment objects).

### Cross-cutting state (the one hard problem)
`log`, `errorMessage`, and the busy flags stay on `AppModel` (they are app-level UI state). Controllers report upward through **injected closures**, mirroring LiveAstroCore's own `onLog` idiom:

```swift
struct AppSurface {              // constructed by AppModel, handed to each controller
    let log: (String) -> Void            // appends to AppModel.log
    let presentError: (String) -> Void   // sets AppModel.errorMessage
}
```
Controllers never hold a reference to `AppModel` (no cycles, unit-testable with captured closures). Busy flags: flags that are *conceptually domain state* move with their controller (`broadcastState` → Broadcast; `isDetecting` → LiveSource; `isImporting`, `importProcessed/Total` → Import); flags that gate *cross-domain* behavior (`isRunning`) stay on `AppModel`, and controllers that need to read them receive them as closure inputs (`let isSessionRunning: () -> Bool` in `AppSurface`) — never as stored back-references.

### Stage T1 — `BroadcastController` (`Sources/LiveAstroStudio/BroadcastController.swift`)
Moves: `obs` (OBSController), connection config (`obsHost/Port/Password/AutoLaunch/Record`), scene automation config+state (`sceneAutomationOn`, `stackSceneName`, `scopeSceneName`, `sceneTimer`, `stall`, `showingScopeDueToStall`, `manualOverride`, `lastAutomationScene`), `broadcastState`, `streamHealth`, `healthPollTask`, `goLiveTask`, `obsBundleID`, and methods `connectOBS`, `goLive`, `endBroadcast`, `startHealthPoll`, `launchOBS`, `startSceneAutomation`, `stopSceneAutomation`, `sceneTick`, `onFrameAccepted` (the scene-automation part), `setSceneViaAutomation`, `detectManualOverride`.
Session hooks: `AppModel` calls `broadcast.sessionDidStart(stallSource:)` / `broadcast.sessionDidEnd()` / `broadcast.frameAccepted()` at the same points the logic fires today. Settings: OBS fields remain in `SessionSettings` unchanged; `AppModel.currentSettings()/loadSettings()` read/write `broadcast.*` (blob format untouched).
Views: `BroadcastView` re-points `$model.obsHost` → `$model.broadcast.obsHost` etc.

### Stage T2 — `LiveSourceController` (`Sources/LiveAstroStudio/LiveSourceController.swift`)
Moves: `frameRelay`, `isDetecting`, `relayRetentionDays`, `pruneRelay`, `startWatchFolderLive`, `configureAndStartWatchFolder`, `startSeestarLive`, `configureAndStartSeestar`, `startASIAIRLive`, `configureAndStartASIAIR`, and the willTerminate relay-stop.
Seam back into session start: the three configure paths currently set profile fields (`targetName`, `subExposureText`, `fileNamePrefix`, `neutralizeBackground`, `sourceMode`, `watchFolder`) and call `startSession()`/`saveSettings()` — those become `AppSurface` extensions for this controller (`let applyDetectedProfile: (DetectedProfile) -> Void`, `let startSession: () -> Void`, `let saveSettings: () -> Void`) with a small `DetectedProfile` value struct, so the controller stays reference-free. Relay `onLog` keeps flowing to the app log via `surface.log`.
Views: `ControlView`'s Start Seestar/ASIAIR/Choose Folder buttons and the "Keep relay sessions" picker re-point to `model.liveSource.*`.

### Stage T3 — `ImportController` (`Sources/LiveAstroStudio/ImportController.swift`)
Moves: `importPipeline`, `isImporting`, `importProcessed/importTotal`, `importSubs(from:)`, `cancelImport`, plus post-processing `regenerateReplay`, `processMaster`, `isProcessing`, `isGeneratingReplay`. (Post-processing rides with import: same "operate on a finished session dir" character; keeps stage count at 3.)
Inputs via `AppSurface` extensions: `makeStackEngine: () -> StackEngine`, calibration access, `neutralizeBackground/fileNamePrefix/liveAstroRoot` getters, profile-metadata update closure (the header-fill behavior from the import-profile fix), and result publication (`setReplayURL`, `setLastSessionDirectory`) OR those two stay controller-owned with views re-pointed — decided in the plan by whichever keeps view diffs smaller.
Views: import progress/cancel and replay/GraXpert buttons re-point to `model.importer.*`.

### Stage T4 — residual `AppModel` audit
What remains: session profile draft, settings persistence (now delegating controller fields), session lifecycle (`startSession`, `wireCallbacks`, `reseedReference`, `endSession`, `makeStackEngine`, `applyDisplayAdjustments`), shared UI state (`log`, `errorMessage`, `isRunning`, `latestImage/latestRecord`, counts, `zoomPan`, `displayAdjustments`, tabs), controller ownership + `AppSurface` construction. Target ≤ ~450 lines (hard cap: it must be smaller than ControlView's 499). T4 also updates any doc comments and runs the whole-branch gates.

## Zero-behavior-change guards

- Full `swift test` (480+) green at EVERY stage boundary — the merge gate is the suite plus release build.
- Settings compatibility pinned: the existing SessionSettings round-trip/backward-compat tests must pass unmodified (blob format frozen).
- Log-line strings and error messages move verbatim (fault-matrix clause-6 tests pin several).
- Manual smoke per stage: app launches, the moved surface works (T1: OBS panel binds; T2: a Start Seestar attempt logs the detect line; T3: an import runs).
- No logic edits: diffs should read as moves + seam wiring. Any behavioral improvement discovered en route is ledgered, not done.

## Swift 6 note
The decomposition does not chase the 260-survey diagnostics, but each controller is created `@MainActor @Observable` from birth and keeps the strong-let detached-task idiom from step 3, so no new diagnostics are introduced and future strict-mode work gets smaller files.

## Testing
Behavior is guarded by the existing 480-test suite + the stage smokes. New unit tests are added only where extraction creates a newly testable seam cheaply (e.g., `LiveSourceController` detect-path wiring with a stub `AppSurface` asserting `applyDetectedProfile`/`startSession` calls; `BroadcastController` scene-automation state transitions with a stubbed OBS) — a handful per controller, not a re-test of moved logic.

## Task Order (for the plan)
1. **T1 — BroadcastController** extraction + BroadcastView re-point + smoke.
2. **T2 — LiveSourceController** extraction + ControlView re-point + smoke.
3. **T3 — ImportController** (+ post-processing) extraction + re-point + smoke.
4. **T4 — residual audit** (size cap, doc comments) + whole-branch review + adversarial-style behavioral-parity check + merge.
