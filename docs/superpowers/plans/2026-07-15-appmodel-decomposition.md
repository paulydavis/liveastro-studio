# AppModel Decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 891-line `AppModel` into three owned controllers (Broadcast, LiveSource, Import) plus a ≤450-line residual, zero behavior change, staged so every task ships green independently.

**Architecture:** Each controller is a `@MainActor @Observable final class` owned by `AppModel` as a `let`; views reach it via `model.<controller>` (environment unchanged). Cross-cutting state stays on `AppModel`; controllers report upward through an injected `AppSurface` closure bundle (no back-references). Moves are verbatim; diffs must read as moves + seam wiring.

**Tech Stack:** Swift 5.10 SPM, SwiftUI @Observable composition.

## Global Constraints

- **Zero behavior change.** Same log strings (fault-matrix clause-6 tests pin several), same error messages, same settings blob (existing SessionSettings round-trip/backward-compat tests must pass UNMODIFIED), same UI behavior.
- Full `swift test` green + `swift build -c release` clean at EVERY task boundary — the only merge gates (filtered runs never suffice — house rule).
- Controllers: `@MainActor @Observable final class`, created from birth with the step-3 idiom (detached tasks rebind weak self to a strong let; zero #SendableClosureCaptures warnings — check with a build after each task).
- No logic edits during moves. Behavioral improvements discovered en route are LEDGERED, not made.
- Busy-flag rule: domain state moves with its controller (`broadcastState`, `isDetecting`, `isImporting`, `importProcessed/Total`, `isProcessing`, `isGeneratingReplay`); cross-domain gates stay on AppModel (`isRunning`).
- Residual AppModel hard cap: < 499 lines (smaller than ControlView).
- Branch: `feature/appmodel-decomposition` off `main` @ 497ec23. Spec: `docs/superpowers/specs/2026-07-15-appmodel-decomposition-design.md` (its Architecture section enumerates every member each stage moves — it is the authoritative move-list).
- iCloud build.db noise: judge by suite results; `rm -rf .build` if edits seem stale; ONE swift process at a time.

## The shared seam (created in T1, extended in T2/T3)

```swift
// Sources/LiveAstroStudio/AppSurface.swift
import Foundation
import LiveAstroCore

/// Upward-reporting seam handed by AppModel to each controller. Controllers hold
/// NO reference to AppModel — every cross-cutting effect flows through these
/// closures (mirrors LiveAstroCore's onLog idiom; unit-testable with captures).
@MainActor
struct AppSurface {
    let log: (String) -> Void                 // append to AppModel.log
    let presentError: (String) -> Void        // set AppModel.errorMessage
    let isSessionRunning: () -> Bool          // read AppModel.isRunning
    // T2 additions:
    var applyDetectedProfile: ((DetectedProfile) -> Void)? = nil
    var startSession: (() -> Void)? = nil
    var saveSettings: (() -> Void)? = nil
    // T3 additions:
    var makeStackEngine: (() -> StackEngine)? = nil
    var setReplaySession: ((URL /*replayURL*/, URL /*sessionDir*/) -> Void)? = nil
}

/// What a detect path learned about the source (T2).
struct DetectedProfile {
    var targetName: String?
    var subExposureText: String?
    var fileNamePrefix: String?
    var neutralizeBackground: Bool?
    var sourceMode: AppModel.SourceMode?
    var watchFolder: URL?
}
```
(Optional closure fields keep one struct across stages; each controller asserts the fields it needs at init via preconditions.)

---

## Task 1: `BroadcastController` extraction

**Files:**
- Create: `Sources/LiveAstroStudio/AppSurface.swift` (code above, T1 fields only — add the T2/T3 optionals now, unused)
- Create: `Sources/LiveAstroStudio/BroadcastController.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`, `Sources/LiveAstroStudio/BroadcastView.swift`, `Sources/LiveAstroStudio/ControlView.swift` (OBS settings rows if any live there — grep `obsHost` etc.)

**Move-list (verbatim from AppModel — the spec's T1 list; grep each name):** `obs`, `obsHost`, `obsPort`, `obsPassword`, `obsAutoLaunch`, `obsRecord`, `sceneAutomationOn`, `stackSceneName`, `scopeSceneName`, `broadcastState` (+ `BroadcastState` enum), `streamHealth`, `healthPollTask`, `goLiveTask`, `obsBundleID`, `sceneTimer`, `stall`, `showingScopeDueToStall`, `manualOverride`, `lastAutomationScene`, and methods `connectOBS`, `goLive`, `endBroadcast`, `startHealthPoll`, `launchOBS`, `startSceneAutomation`, `stopSceneAutomation`, `sceneTick`, `setSceneViaAutomation`, `detectManualOverride`, plus the scene-automation part of `onFrameAccepted` and the OBS wiring in `init` (`obs.onLog` → `surface.log("OBS: …")`).

**Controller skeleton:**
```swift
// Sources/LiveAstroStudio/BroadcastController.swift
import SwiftUI
import LiveAstroCore

@MainActor @Observable
final class BroadcastController {
    private let surface: AppSurface
    init(surface: AppSurface) { self.surface = surface /* + obs.onLog wiring */ }

    // moved config/state properties…
    // moved methods…

    // Session hooks called by AppModel at the exact points the logic fires today:
    func sessionDidStart(stall detector: StallDetector?)   // was startSceneAutomation call site
    func sessionDidEnd()                                    // was stopSceneAutomation + stopStream block
    func frameAccepted()                                    // was onFrameAccepted's scene part
}
```

**AppModel wiring:**
```swift
    let broadcast: BroadcastController
    init() {
        // AppSurface must be built without capturing self before init completes:
        // construct with closures that capture `self` unowned AFTER phase-1 —
        // simplest correct form: make `broadcast` a lazy-initialized let via an
        // implicitly-unwrapped private var, or initialize with a factory after
        // super-init pattern. CHOOSE the simplest that compiles warning-free and
        // document it; do not redesign.
        …
    }
```
`currentSettings()`/`loadSettings()` re-point OBS fields to `broadcast.*` (blob keys unchanged). `startSession`/`endSession`/`wireCallbacks` call the three hooks where the moved logic used to run inline. `BroadcastView` bindings: `$model.obsHost` → `$model.broadcast.obsHost` (mechanical, ~15 sites — grep `model.obs`, `model.broadcastState`, `model.streamHealth`, `model.goLive`, `model.endBroadcast`, `model.sceneAutomation`, `model.stackScene`, `model.scopeScene`).

- [ ] **Step 1:** Create AppSurface.swift + BroadcastController.swift with the verbatim-moved members; wire AppModel; re-point views. Build until zero errors AND zero warnings.
- [ ] **Step 2:** New seam tests (cheap, `Tests/LiveAstroCoreTests/` is core-only — these go in a NEW app-target test approach? NO: the app target has no test target. Instead: the controller's testability is documented; behavior stays guarded by the suite + smoke. Skip unit tests for T1 — note this in the report).
- [ ] **Step 3:** Gates: full `swift test` (480+/0) + `swift build -c release` + settings tests unmodified-and-green + zero SendableClosureCaptures.
- [ ] **Step 4:** Smoke: launch `dist` debug build or `swift run LiveAstroStudio` is not packaged — instead run the app from Xcode-less: build release, repackage NOT needed mid-branch; smoke = the controller compiles into the app and the suite's OBS tests (OBSController/OBSClient) still pass. Manual smoke happens at T4 merge.
- [ ] **Step 5:** Commit: `refactor: extract BroadcastController from AppModel (T1, zero behavior change)`.

---

## Task 2: `LiveSourceController` extraction

**Files:** Create `Sources/LiveAstroStudio/LiveSourceController.swift`; modify AppModel, AppSurface (activate T2 closures), ControlView.

**Move-list:** `frameRelay`, `isDetecting`, `relayRetentionDays`, `pruneRelay`, `startWatchFolderLive`, `configureAndStartWatchFolder`, `startSeestarLive`, `configureAndStartSeestar`, `startASIAIRLive`, `configureAndStartASIAIR`, the willTerminate observer's relay-stop (AppModel keeps the observer, calls `liveSource.stopRelay()`).

Seam: the configure paths' profile-field writes become ONE `surface.applyDetectedProfile(DetectedProfile(...))` call each (AppModel applies the non-nil fields to its draft properties — behavior identical), then `surface.saveSettings?()` / `surface.startSession?()` at the same points as today. `watcher/relay onLog` keeps flowing via `surface.log`. `relayRetentionDays` persists via `currentSettings()` reading `liveSource.relayRetentionDays`.

Views: `ControlView` — `model.startSeestarLive()` → `model.liveSource.startSeestarLive()` etc.; `$model.relayRetentionDays` → `$model.liveSource.relayRetentionDays`; `isDetecting` reads re-pointed.

Steps mirror T1 (move → wire → re-point → gates → commit `refactor: extract LiveSourceController (T2, zero behavior change)`), plus: the fault-matrix and relay/watcher tests must stay green UNMODIFIED (they exercise LiveAstroCore, not the app — verify no accidental core edits).

---

## Task 3: `ImportController` extraction

**Files:** Create `Sources/LiveAstroStudio/ImportController.swift`; modify AppModel, AppSurface (activate T3 closures), ControlView.

**Move-list:** `importPipeline`, `isImporting`, `importProcessed`, `importTotal`, `importSubs(from:)`, `cancelImport`, `regenerateReplay(sessionDirectory:)`, `processMaster(sessionDirectory:)`, `isProcessing`, `isGeneratingReplay`.

Seams: `surface.makeStackEngine!()` for the engine; calibration + `neutralizeBackground` + `fileNamePrefix` + `liveAstroRoot` read via small closure getters added to AppSurface in this task (follow the established optional-field pattern); import's header-driven profile fill reuses `applyDetectedProfile`; results publish via `surface.setReplaySession(replayURL, sessionDir)` (AppModel keeps `replayURL`/`lastSessionDirectory` — smaller view diff, decided per spec). `wireCallbacks` stays on AppModel (session-shared); importSubs' call to it becomes a closure input if needed — prefer moving the import-specific callback wiring INTO the controller if it doesn't touch AppModel state beyond what AppSurface provides; otherwise closure. Document the choice.

Views: import progress bar/cancel + Regenerate/GraXpert buttons re-point to `model.importer.*`.

Steps mirror T1; commit `refactor: extract ImportController (T3, zero behavior change)`.

---

## Task 4: Residual audit + gates + merge prep

- [ ] **Step 1:** `wc -l Sources/LiveAstroStudio/AppModel.swift` — must be < 499. If not, identify what else is movable within the spec's boundaries (do NOT invent new controllers; small helpers may move next to their controller).
- [ ] **Step 2:** Doc comments: AppModel's header comment describes the new shape (owner of controllers + session lifecycle + shared UI state); each controller gets a 3-5 line responsibility header.
- [ ] **Step 3:** Full gates one more time (suite, release, zero warnings, settings tests unmodified).
- [ ] **Step 4:** Line-count table in the report (before: AppModel 891; after: AppModel n + controllers a/b/c + AppSurface d).
- [ ] **Step 5:** Commit `refactor: residual AppModel audit (T4)`.

## After all tasks
Whole-branch review (opus): behavioral parity focus — every moved log/error string byte-identical (grep-diff the string literals between main and branch), settings blob unchanged, hook call-order identical, no logic drift in moves; plus the standard quality lens. A parity-focused cold pass: "find one behavior that changed" (diff-driven: string literals, call order, state transitions). Then merge + push + repackage + MANUAL smoke (Paul or controller drives the app once: OBS panel binds, Seestar detect logs, an import runs).
