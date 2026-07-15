import Foundation

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
    /// Reads `AppModel.isImporting` — a cross-domain gate the start*Live paths
    /// check today. Import state moves to ImportController in T3, at which point
    /// this closure is removed and the controller reads it from that seam. // T3 removes
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

    // MARK: T3 — ImportController seam (declared, unused until T3)

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
