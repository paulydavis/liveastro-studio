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

    // MARK: T2 — LiveSourceController seam (declared, unused until T2)

    /// Applies an auto-detected capture profile onto the session draft.
    var applyDetectedProfile: ((DetectedProfile) -> Void)?
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
         applyDetectedProfile: ((DetectedProfile) -> Void)? = nil,
         startSession: (() -> Void)? = nil,
         saveSettings: (() -> Void)? = nil,
         setReplayURL: ((URL) -> Void)? = nil,
         setLastSessionDirectory: ((URL) -> Void)? = nil) {
        self.log = log
        self.presentError = presentError
        self.isSessionRunning = isSessionRunning
        self.applyDetectedProfile = applyDetectedProfile
        self.startSession = startSession
        self.saveSettings = saveSettings
        self.setReplayURL = setReplayURL
        self.setLastSessionDirectory = setLastSessionDirectory
    }
}

/// Placeholder value type for the T2 detect-path seam (populated at T2).
struct DetectedProfile {}
