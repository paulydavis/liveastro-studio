import Foundation
import LiveAstroCore

/// The seam between `AppModel` and its extracted controllers.
///
/// Controllers never hold a reference to `AppModel` (no retain cycles, and they
/// stay unit-testable with captured closures). Instead `AppModel` constructs one
/// `AppSurface` — a bundle of closures over its cross-cutting UI state — and
/// hands it to each controller. This mirrors LiveAstroCore's own `onLog` idiom.
///
/// Only the T1 (`BroadcastController`) fields are wired today. The T2/T3 fields
/// are declared now, defaulted to no-ops, so later stages add controllers
/// without re-touching this type's shape.
struct AppSurface {

    // MARK: Cross-cutting UI state (used by T1)

    /// Appends a line to `AppModel.log` (main-actor).
    let log: (String) -> Void
    /// Sets `AppModel.errorMessage`, driving the error alert.
    let presentError: (String) -> Void
    /// Reads `AppModel.isRunning` — a cross-domain gate the controller must not
    /// store as a back-reference.
    let isSessionRunning: () -> Bool
    /// Reads `isImporting` — a cross-domain gate the start*Live paths check.
    /// Import state now lives on `ImportController` (T3); `AppModel` backs this
    /// closure with `importer.isImporting`, so `LiveSourceController` keeps
    /// reading the gate through the seam without a back-reference.
    let isImporting: () -> Bool

    // MARK: T2 — LiveSourceController seam (declared, unused until T2)

    /// Applies an auto-detected capture profile onto the session draft.
    var applyDetectedProfile: ((DetectedProfile) -> Void)?
    /// Reads the current draft `targetName` (the watch-folder relay path reads it
    /// back after `applyDetectedProfile` to name the relay directory).
    var currentTargetName: (() -> String)?
    /// Resets the viewer zoom/pan to fit — the start*Live paths do this up front
    /// before the async detect, matching the old inline `zoomPan = .fit`.
    var resetZoomPan: (() -> Void)?
    /// Switches the UI to the Live tab — the configure paths do this after a
    /// successful start, matching the old inline `selectedTab = .live`.
    var selectLiveTab: (() -> Void)?
    /// Starts a live session using the current draft.
    var startSession: (() -> Void)?
    /// Persists current settings.
    var saveSettings: (() -> Void)?

    // MARK: T3 — ImportController seam

    /// Builds a stacking engine from the current stacker settings — the import
    /// path stacks natively, so it needs the same engine `startSession` uses.
    var makeStackEngine: (() -> StackEngine)?
    /// Reads the current calibration selection (dark/flat paths) for the import
    /// calibrator; import saves it back to the standard store like the live path.
    var currentCalibration: (() -> CalibrationSelection)?
    /// Reads the current `neutralizeBackground` draft flag.
    var currentNeutralizeBackground: (() -> Bool)?
    /// Reads the current `fileNamePrefix` draft field (drives the folder glob and
    /// the zero-match message).
    var currentFileNamePrefix: (() -> String)?
    /// Reads the session-output root (`AppModel.liveAstroRoot`).
    var currentLiveAstroRoot: (() -> URL)?
    /// Reads the current session profile draft.
    var currentProfile: (() -> SessionProfile)?
    /// Reads the selected post-processor backend (GraXpert gate in processMaster).
    var currentProcessorBackend: (() -> ProcessorBackend)?
    /// Wires the shared pipeline callbacks (`onUpdate`/`onRejected`/`onLog`) — the
    /// same session-shared wiring `startSession` uses; stays on `AppModel` because
    /// it writes cross-cutting session state (`latestImage`, counts, log).
    var wireImportCallbacks: ((SessionPipeline, @escaping () -> Void) -> Void)?
    /// Publishes the running accepted/rejected counts (import progress writes the
    /// same cross-cutting counters the live path does).
    var setAcceptedRejectedCounts: ((Int, Int) -> Void)?

    /// Publishes the generated replay URL.
    var setReplayURL: ((URL) -> Void)?
    /// Publishes the finished session directory.
    var setLastSessionDirectory: ((URL) -> Void)?

    init(log: @escaping (String) -> Void,
         presentError: @escaping (String) -> Void,
         isSessionRunning: @escaping () -> Bool,
         isImporting: @escaping () -> Bool = { false },
         applyDetectedProfile: ((DetectedProfile) -> Void)? = nil,
         currentTargetName: (() -> String)? = nil,
         resetZoomPan: (() -> Void)? = nil,
         selectLiveTab: (() -> Void)? = nil,
         startSession: (() -> Void)? = nil,
         saveSettings: (() -> Void)? = nil,
         makeStackEngine: (() -> StackEngine)? = nil,
         currentCalibration: (() -> CalibrationSelection)? = nil,
         currentNeutralizeBackground: (() -> Bool)? = nil,
         currentFileNamePrefix: (() -> String)? = nil,
         currentLiveAstroRoot: (() -> URL)? = nil,
         currentProfile: (() -> SessionProfile)? = nil,
         currentProcessorBackend: (() -> ProcessorBackend)? = nil,
         wireImportCallbacks: ((SessionPipeline, @escaping () -> Void) -> Void)? = nil,
         setAcceptedRejectedCounts: ((Int, Int) -> Void)? = nil,
         setReplayURL: ((URL) -> Void)? = nil,
         setLastSessionDirectory: ((URL) -> Void)? = nil) {
        self.log = log
        self.presentError = presentError
        self.isSessionRunning = isSessionRunning
        self.isImporting = isImporting
        self.applyDetectedProfile = applyDetectedProfile
        self.currentTargetName = currentTargetName
        self.resetZoomPan = resetZoomPan
        self.selectLiveTab = selectLiveTab
        self.startSession = startSession
        self.saveSettings = saveSettings
        self.makeStackEngine = makeStackEngine
        self.currentCalibration = currentCalibration
        self.currentNeutralizeBackground = currentNeutralizeBackground
        self.currentFileNamePrefix = currentFileNamePrefix
        self.currentLiveAstroRoot = currentLiveAstroRoot
        self.currentProfile = currentProfile
        self.currentProcessorBackend = currentProcessorBackend
        self.wireImportCallbacks = wireImportCallbacks
        self.setAcceptedRejectedCounts = setAcceptedRejectedCounts
        self.setReplayURL = setReplayURL
        self.setLastSessionDirectory = setLastSessionDirectory
    }
}

/// The set of session-draft fields an auto-detect/relay path writes before it
/// starts a session. Carries exactly the fields a given path sets; `AppModel`'s
/// `applyDetectedProfile` writes only the non-nil ones onto its draft, so each
/// path's effect is byte-identical to the old inline field writes.
struct DetectedProfile {
    var sourceMode: AppModel.SourceMode?
    var neutralizeBackground: Bool?
    var targetName: String?
    var subExposureText: String?
    var fileNamePrefix: String?
    var watchFolder: URL?
}
