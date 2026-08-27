import SwiftUI
import AppKit
import LiveAstroCore

/// Coordination hub for LiveAstro Studio.
///
/// Owns the three extracted controllers (`broadcast`, `liveSource`, `importer`) via
/// `AppSurface`-backed composition; each controller is reference-free (no back-pointer
/// to `AppModel`). Retains: session lifecycle (`startSession` / `wireCallbacks` /
/// `endSession`), settings persistence (`loadSettings` / `saveSettings`), the session
/// profile draft (form fields bound to `ControlView`), and shared UI state (`log`,
/// `errorMessage`, `isRunning`, `latestImage/Record`, counts, `zoomPan`, tabs).
@Observable
@MainActor
final class AppModel {

    enum MainTab: String, CaseIterable { case live = "Live", setup = "Setup", help = "Help" }
    var selectedTab: MainTab = .setup
    var isDetached = false

    enum SetupSubTab: Hashable { case capture, display, stats, broadcast, diagnostics }
    var setupSubTab: SetupSubTab = .capture

    enum SourceMode: String, CaseIterable {
        case stackerOutput = "Stacker output (Siril)"
        case nativeStack   = "Raw subs (native stacking)"

        /// Typical capture filename prefix for the mode (Siril writes live_stack_*,
        /// capture software writes Light_*).
        var defaultFileNamePrefix: String {
            switch self {
            case .stackerOutput: return "live_stack"
            case .nativeStack:   return "Light_"
            }
        }
    }

    // Session profile draft (bound to the control form)
    var targetName = ""
    var telescope = ""
    var camera = ""
    var mount = ""
    var filter = ""
    var locationLabel = ""
    var bortleText = ""
    var subExposureText = "60"
    var notes = ""

    var fileNamePrefix = SourceMode.stackerOutput.defaultFileNamePrefix
    var neutralizeBackground = false

    // Session completion draft (bound to the Setup "Session end" group; assembled
    // into SessionSettings by currentSettings() and restored by loadSettings()).
    // These are the LIVE values the completion tick reads via
    // currentSettings().completionSettings — without them the tick would only ever
    // see SessionSettings defaults (planned stop unreachable in production).
    var idleSafeguardEnabled = true
    var idleSafeguardMinutes = 15
    var plannedStopEnabled = false {
        didSet {
            // Arm/disarm on the enable flip. The armed-at timestamp anchors the
            // planned-stop deadline (both the tick driver and the Live-tab display),
            // so a mid-session enable at 11:30 PM with a 10 PM stop resolves to 10 PM
            // the NEXT day instead of firing immediately.
            guard plannedStopEnabled != oldValue else { return }
            plannedStopArmedAt = plannedStopEnabled ? Date() : nil
        }
    }
    var plannedStopHour = 3 {
        didSet { rearmPlannedStopIfEnabled(changed: plannedStopHour != oldValue) }
    }
    var plannedStopMinute = 0 {
        didSet { rearmPlannedStopIfEnabled(changed: plannedStopMinute != oldValue) }
    }
    /// When planned-stop was last enabled or its time last changed — the anchor for
    /// the planned-stop deadline. nil while disabled. loadSettings() assigns the
    /// draft on launch, so this becomes launch time (deadline = next occurrence
    /// after launch, which is the intended behavior).
    var plannedStopArmedAt: Date?
    /// Re-arm (reset armed-at to now) when the stop time changes while enabled.
    private func rearmPlannedStopIfEnabled(changed: Bool) {
        guard changed, plannedStopEnabled else { return }
        plannedStopArmedAt = Date()
    }
    var rejectionEnabled = true
    var rejectionStrength: RejectionStrength = .medium
    var frameWeightingEnabled = true
    var backgroundNormalizationEnabled = true
    var scaleNormalizationEnabled = true
    var demosaic: DemosaicMethod = .malvar
    var calibration = CalibrationStore.load(.standard)

    /// Reusable master darks/bias, matched to a session by camera + settings.
    let calibrationLibrary = CalibrationLibrary()
    /// Per-session flat frames (shot fresh each night) — a folder of raw flats built now.
    var sessionFlatsFolder: URL?
    /// Optional per-session dark-flats folder (offset subtracted when building the flat).
    var sessionDarkFlatsFolder: URL?
    /// Scale a library dark across exposures using bias when no exact-exposure dark exists.
    var scaleDarksAcrossExposures = true
    /// Latest auto-match status line, shown in the Calibration section.
    var calibrationStatus = ""
    /// Observable mirror of the on-disk library, for the Calibration list UI.
    var libraryEntries: [MasterFrame] = []
    /// True while a master is building/rebuilding (disables the add buttons).
    var calibrationBusy = false

    var watchFolder: URL?
    var sourceMode: SourceMode = .stackerOutput {
        didSet {
            // Swap the prefix default with the mode, but never clobber a user-edited value.
            guard sourceMode != oldValue else { return }
            if fileNamePrefix == oldValue.defaultFileNamePrefix {
                fileNamePrefix = sourceMode.defaultFileNamePrefix
            }
        }
    }
    var isRunning = false
    /// Accepted frames this session; updated only in .nativeStack mode
    /// (watcher mode reads 0 — use latestRecord?.index instead).
    var acceptedCount = 0
    var rejectedCount = 0
    /// Main-actor mirror of the per-sub quality records the pipeline persists to the
    /// session manifest (Task 8a). Source of truth for the Stats UI and the re-stack
    /// excluded set. Appended from `pipeline.onSubFrame`; the pipeline itself already
    /// wrote the record to `session.subFrames` on its own callback thread, so this
    /// handler is UI-mirror only (no manifest write here — that would race the
    /// consume task; see Task 8 Refinement in the sub-stats plan).
    private(set) var subFrames: [SubFrameRecord] = []
    /// True while a re-stack (Task 8b) is rebuilding the master off the main actor.
    /// Guards against concurrent restack runs; also usable to disable the re-stack
    /// button in the Stats UI (Task 10).
    private(set) var isRestacking = false
    /// True right after a session ends with flagged subs on record — surfaces a non-blocking
    /// "re-stack for a clean final master?" confirm in StatsView (Task 11). Never triggers a
    /// re-stack automatically; the operator must tap "Re-stack now".
    var restackOfferPending = false
    /// The calibrator the just-ended session's pipeline actually applied (explicit or
    /// auto-resolved from the first frame). Captured in `endSession` before the pipeline is
    /// released so a post-session re-stack reuses the SAME calibration the live master used —
    /// rebuilding from legacy config paths (usually nil) would overwrite a calibrated
    /// master.fit with an uncalibrated one (Fix 1). Nil = an uncalibrated session → identity.
    private var sessionCalibrator: Calibrator?
    /// The watch folder / file-name prefix captured at session START, so a re-stack lists the
    /// session's own subs even if the operator changed the live `watchFolder`/`fileNamePrefix`
    /// (or source mode) after End but before Re-stack (Fix 4).
    private var restackSourceDir: URL?
    private var restackPrefix: String = ""
    var latestImage: CGImage?
    var latestRecord: SnapshotRecord?
    var sessionStart: Date?
    var sessionEnd: Date?
    var log: [String] = []
    var replayURL: URL?
    var processorBackend: ProcessorBackend = .none
    var displayAdjustments = DisplayAdjustments.liveDefault

    /// Red night-vision tint of the *whole Mac display* (not just the astro image).
    /// In-memory only — defaults off each launch so the app never opens unexpectedly red.
    var nightVisionOn = false
    /// Tint brightness 1...100 (Double for the slider); lower is dimmer.
    var nightVisionLevel = Double(NightVision.defaultLevel)
    private let nightMode = NightModeController()

    /// Apply the current night-vision on/off + level to the display. Called from the
    /// control-panel toggle and slider.
    func applyNightVision() {
        if nightVisionOn { nightMode.enable(level: Int(nightVisionLevel)) }
        else { nightMode.disable() }
    }

    /// True once the reference frame has been plate-solved — gates the "North up" toggle. Refreshed on
    /// each display update from `pipeline.hasSolvedWCS`.
    private(set) var solveAvailable = false

    /// Whether the (download-on-demand) star catalog needed for plate-solving / north-up is present.
    enum CatalogState: Equatable { case notInstalled, downloading(Double), installed, failed(String) }
    private(set) var catalogState: CatalogState = CatalogInstaller.isInstalled() ? .installed : .notInstalled

    private(set) var lastSessionDirectory: URL?
    var errorMessage: String?
    var zoomPan = ZoomPanState.fit

    /// Drives the error alert; dismissal (setting false) clears errorMessage.
    /// Setting true directly is a no-op — present errors via errorMessage.
    var isShowingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // MARK: - Broadcast

    /// OBS / broadcast / scene-automation cluster (T1 extraction; core-resident
    /// since review6 — constructed here with an injected `OBSController` and the
    /// `BroadcastDeps` closure seam). Owned here as an implicitly-unwrapped
    /// `let`-in-spirit: it's assigned exactly once, early in `init`, before any
    /// use — the IUO is only to break the init-order knot (the `BroadcastDeps`
    /// closures capture `self`, so `broadcast` cannot be a
    /// stored `let` initialized in its declaration). Assigned exactly once in
    /// `init` and never reassigned — the `var` (rather than `private(set) var`)
    /// is required only so SwiftUI can form writable bindings through it
    /// (`$model.broadcast.obsHost`); the reference itself is never rebound.
    var broadcast: BroadcastController!

    /// Set by `MainView` (the only View with `@Environment(\.openWindow)` in
    /// scope) so `BroadcastDeps.openBroadcastWindow` can request the
    /// "broadcast" window — the same `openWindow(id: "broadcast")` path the
    /// Detach button uses — without `AppModel` touching SwiftUI's
    /// window-opening API directly. Nil until `MainView` wires it; the T5
    /// pre-flight capture stage already tolerates a slow-to-appear window
    /// (bounded poll of `broadcastWindowID`).
    var openBroadcastWindowHandler: (() -> Void)?

    /// Live-source orchestration cluster (T2 extraction): the frame relay, its
    /// retention policy, and the three auto-detect/configure paths. Same IUO
    /// init-order rationale as `broadcast` above — assigned exactly once early in
    /// `init` (its `AppSurface` closures capture `self`, so it can't be a stored
    /// `let`), never reassigned; `var` only so SwiftUI can bind through it
    /// (`$model.liveSource.relayRetentionDays`).
    var liveSource: LiveSourceController!

    /// Import + post-processing cluster (T3 extraction): one-shot batch import and
    /// its progress/cancel state, plus the replay-regenerate and GraXpert-master
    /// actions over a finished session directory. Same IUO init-order rationale as
    /// `broadcast`/`liveSource` above — assigned exactly once early in `init` (its
    /// `AppSurface` closures capture `self`, so it can't be a stored `let`), never
    /// reassigned; `var` only so SwiftUI can bind through it.
    var importer: ImportController!

    private var pipeline: SessionPipeline?
    private var demoTask: Task<Void, Never>?

    /// Snapshot of the user's real session settings, captured when a Try-Demo
    /// session overrides them with demo values (branding: "Demo Nebula", 30 s,
    /// "Demo Stack Generator", …; and source config: stacker-output mode, the
    /// DemoInput folder, the demo prefix). Restored when the demo session ends so
    /// a later real session — and the persisted settings — never inherit the demo
    /// branding OR point at the demo folder/prefix. nil when no demo override is active.
    private struct DemoMetadataSnapshot {
        var targetName, telescope, camera, mount, filter, locationLabel: String
        var bortleText, subExposureText, notes: String
        var sourceMode: SourceMode
        var watchFolder: URL?
        var fileNamePrefix: String
    }
    private var metadataBeforeDemo: DemoMetadataSnapshot?

    // MARK: - Session completion (spec §2)

    /// Per-session completion state (idle safeguard + planned stop flags, re-arm).
    private var completionDriver = SessionCompletionDriver()
    /// Timestamp of the most recent accepted frame; drives the idle safeguard.
    /// Updated on every accepted frame in both source modes (the `onAccepted`
    /// hook fires for each accepted update regardless of mode).
    private(set) var lastAcceptedFrame: Date?
    /// The 30 s tick that polls `completionDriver`; started on a successful
    /// `startSession()` and cancelled in `endSession()`.
    private var completionTick: Task<Void, Never>?
    private let notifier = SessionNotifier()

    init() {
        // Build the seam bundle and the Broadcast controller first. The closures
        // capture `self` (safe: they only fire after init completes), and
        // `broadcast` must exist before loadSettings()/session hooks reference it.
        broadcast = BroadcastController(obs: OBSController(), deps: BroadcastDeps(
            log: { [weak self] message in MainActor.assumeIsolated { self?.log.append(message) } },
            presentError: { [weak self] message in MainActor.assumeIsolated { self?.errorMessage = message } },
            isSessionRunning: { [weak self] in MainActor.assumeIsolated { self?.isRunning ?? false } },
            launchOBS: { [weak self] in
                MainActor.assumeIsolated {
                    OBSLauncher.launch(log: { message in
                        MainActor.assumeIsolated { self?.log.append(message) }
                    })
                }
            },
            openBroadcastWindow: { [weak self] in
                MainActor.assumeIsolated { self?.openBroadcastWindowHandler?() }
            },
            broadcastWindowID: {
                // NSWindow.windowNumber IS the CGWindowID — but it is documented
                // to be <= 0 whenever the window has no window device (never yet
                // ordered in, or released after close). Final review F-1: an
                // invalid id yields nil — the capture stage's bounded poll keeps
                // waiting — instead of trapping in UInt32.init, and a stale
                // deviceless window can no longer shadow the freshly opened one.
                MainActor.assumeIsolated {
                    NSApp.windows
                        .filter { $0.title == "LiveAstro Broadcast" }
                        .compactMap { window in
                            window.windowNumber > 0
                                ? UInt32(exactly: window.windowNumber) : nil
                        }
                        .first
                }
            }))

        // Live-source cluster: same seam, plus the T2 closures for the detect
        // paths (draft writes, tab/zoom, save + start). applyDetectedProfile
        // writes only the non-nil fields — byte-identical to the old inline sets.
        liveSource = LiveSourceController(surface: AppSurface(
            log: { [weak self] message in MainActor.assumeIsolated { self?.log.append(message) } },
            presentError: { [weak self] message in MainActor.assumeIsolated { self?.errorMessage = message } },
            isSessionRunning: { [weak self] in MainActor.assumeIsolated { self?.isRunning ?? false } },
            isImporting: { [weak self] in MainActor.assumeIsolated { self?.importer.isImporting ?? false } },
            applyDetectedProfile: { [weak self] p in MainActor.assumeIsolated { self?.applyDetectedProfile(p) } },
            currentTargetName: { [weak self] in MainActor.assumeIsolated { self?.targetName ?? "" } },
            resetZoomPan: { [weak self] in MainActor.assumeIsolated { self?.zoomPan = .fit } },
            selectLiveTab: { [weak self] in MainActor.assumeIsolated { self?.selectedTab = .live } },
            startSession: { [weak self] in MainActor.assumeIsolated { self?.startSession() } },
            saveSettings: { [weak self] in MainActor.assumeIsolated { self?.saveSettings() } }))

        // Import + post-processing cluster: the shared log/error/session-running
        // seam plus the T3 reads the moved bodies need (stacker engine,
        // calibration, draft fields, profile, root, processor backend), the
        // session-shared callback wiring, and the count/result publishers. Result
        // URLs stay on AppModel; the two setters publish them.
        importer = ImportController(surface: AppSurface(
            log: { [weak self] message in MainActor.assumeIsolated { self?.log.append(message) } },
            presentError: { [weak self] message in MainActor.assumeIsolated { self?.errorMessage = message } },
            isSessionRunning: { [weak self] in MainActor.assumeIsolated { self?.isRunning ?? false } },
            applyDetectedProfile: { [weak self] p in MainActor.assumeIsolated { self?.applyDetectedProfile(p) } },
            saveSettings: { [weak self] in MainActor.assumeIsolated { self?.saveSettings() } },
            makeStackEngine: { [weak self] in MainActor.assumeIsolated { self!.makeStackEngine() } },
            currentCalibration: { [weak self] in MainActor.assumeIsolated { self!.calibration } },
            currentNeutralizeBackground: { [weak self] in MainActor.assumeIsolated { self?.neutralizeBackground ?? false } },
            currentDisplayAdjustments: { [weak self] in MainActor.assumeIsolated { self?.displayAdjustments ?? .neutral } },
            currentFileNamePrefix: { [weak self] in MainActor.assumeIsolated { self?.fileNamePrefix ?? "" } },
            currentLiveAstroRoot: { [weak self] in MainActor.assumeIsolated { self!.liveAstroRoot } },
            currentProfile: { [weak self] in MainActor.assumeIsolated { self!.profile } },
            currentProcessorBackend: { [weak self] in MainActor.assumeIsolated { self?.processorBackend ?? .none } },
            wireImportCallbacks: { [weak self] pipeline, onAnyFrame in
                MainActor.assumeIsolated { self?.wireCallbacks(to: pipeline, onAnyFrame: onAnyFrame) } },
            setAcceptedRejectedCounts: { [weak self] accepted, rejected in
                MainActor.assumeIsolated { self?.acceptedCount = accepted; self?.rejectedCount = rejected } },
            setReplayURL: { [weak self] url in MainActor.assumeIsolated { self?.replayURL = url } },
            setLastSessionDirectory: { [weak self] url in MainActor.assumeIsolated { self?.lastSessionDirectory = url } }))
        loadSettings()

        // Save settings and stop the relay when the app is about to terminate.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveSource.stopRelay()
                self?.demoTask?.cancel()
                self?.saveSettings()
            }
        }
    }

    /// Writes the non-nil fields of a detected capture profile onto the session
    /// draft. Called by `LiveSourceController` through the `AppSurface` seam; each
    /// `if let` matches an old inline field write in a configure path.
    private func applyDetectedProfile(_ p: DetectedProfile) {
        if let v = p.sourceMode { sourceMode = v }
        if let v = p.neutralizeBackground { neutralizeBackground = v }
        if let v = p.targetName { targetName = v }
        if let v = p.subExposureText { subExposureText = v }
        if let v = p.fileNamePrefix { fileNamePrefix = v }
        if let v = p.watchFolder { watchFolder = v }
    }

    // MARK: - Settings persistence

    private func currentSettings() -> SessionSettings {
        SessionSettings(
            sourceModeRaw: sourceMode.rawValue,
            watchFolderPath: watchFolder?.path,
            filePrefix: fileNamePrefix,
            neutralizeBackground: neutralizeBackground,
            subExposureSeconds: Double(subExposureText) ?? 60,
            targetName: targetName,
            calibration: calibration,
            rejectionEnabled: rejectionEnabled,
            rejectionStrength: rejectionStrength,
            frameWeightingEnabled: frameWeightingEnabled,
            backgroundNormalizationEnabled: backgroundNormalizationEnabled,
            scaleNormalizationEnabled: scaleNormalizationEnabled,
            processorBackend: processorBackend,
            displayAdjustments: displayAdjustments,
            relayRetentionDays: liveSource.relayRetentionDays,
            demosaic: demosaic,
            idleSafeguardEnabled: idleSafeguardEnabled,
            idleSafeguardMinutes: idleSafeguardMinutes,
            plannedStopEnabled: plannedStopEnabled,
            plannedStopHour: plannedStopHour,
            plannedStopMinute: plannedStopMinute)
    }

    /// The live completion subset (idle safeguard + planned stop) read from the
    /// draft properties — the same values `currentSettings().completionSettings`
    /// assembles, exposed cheaply for the Live-tab armed status without building a
    /// whole SessionSettings each render.
    var completionSettings: CompletionSettings {
        CompletionSettings(idleSafeguardEnabled: idleSafeguardEnabled,
                           idleSafeguardMinutes: idleSafeguardMinutes,
                           plannedStopEnabled: plannedStopEnabled,
                           plannedStopHour: plannedStopHour,
                           plannedStopMinute: plannedStopMinute)
    }

    /// The planned-stop deadline anchor: the armed-at timestamp, but never earlier
    /// than session start (handles arm-before-then-start-after-the-time edge without
    /// an immediate fire on start). Used by BOTH the completion tick driver and the
    /// Live-tab countdown so display and driver agree on the deadline.
    var plannedStopAnchor: Date {
        let floor = sessionStart ?? Date()
        return max(plannedStopArmedAt ?? floor, floor)
    }

    func saveSettings() {
        var settings = currentSettings()
        // While a Try-Demo override is active, never persist its transient branding
        // OR its source config. Any saveSettings during a demo (start, display-adjust,
        // end) keeps the user's real target/exposure AND real source mode/watch
        // folder/prefix on disk — so a crash or force-quit mid-demo can't leave
        // "Demo Nebula"/30 s or the DemoInput folder/demo prefix in saved settings.
        if let snap = metadataBeforeDemo {
            settings.targetName = snap.targetName
            settings.subExposureSeconds = Double(snap.subExposureText) ?? settings.subExposureSeconds
            settings.sourceModeRaw = snap.sourceMode.rawValue
            settings.watchFolderPath = snap.watchFolder?.path
            settings.filePrefix = snap.fileNamePrefix
        }
        SessionSettingsStore.save(settings, to: .standard)
    }

    /// Restore the user's real metadata captured before a Try-Demo session, so the
    /// demo leaves no residue in the fields (or, via saveSettings, on disk). No-op
    /// when no demo override is active.
    private func restoreMetadataAfterDemoIfNeeded() {
        guard let snap = metadataBeforeDemo else { return }
        targetName = snap.targetName; telescope = snap.telescope; camera = snap.camera
        mount = snap.mount; filter = snap.filter; locationLabel = snap.locationLabel
        bortleText = snap.bortleText; subExposureText = snap.subExposureText; notes = snap.notes
        sourceMode = snap.sourceMode; watchFolder = snap.watchFolder; fileNamePrefix = snap.fileNamePrefix
        metadataBeforeDemo = nil
    }

    func loadSettings() {
        let s = SessionSettingsStore.load(.standard)
        sourceMode = SourceMode(rawValue: s.sourceModeRaw) ?? .stackerOutput
        watchFolder = s.watchFolderPath.map { URL(fileURLWithPath: $0) }
        fileNamePrefix = s.filePrefix
        neutralizeBackground = s.neutralizeBackground
        subExposureText = String(format: "%g", s.subExposureSeconds)
        targetName = s.targetName
        calibration = s.calibration
        rejectionEnabled = s.rejectionEnabled
        rejectionStrength = s.rejectionStrength
        frameWeightingEnabled = s.frameWeightingEnabled
        backgroundNormalizationEnabled = s.backgroundNormalizationEnabled
        scaleNormalizationEnabled = s.scaleNormalizationEnabled
        liveSource.relayRetentionDays = s.relayRetentionDays
        demosaic = s.demosaic
        processorBackend = s.processorBackend
        // Fresh install (no saved settings) starts with the recommended DBE-on look;
        // a returning user keeps whatever they last had.
        displayAdjustments = SessionSettingsStore.exists(.standard) ? s.displayAdjustments : .liveDefault
        idleSafeguardEnabled = s.idleSafeguardEnabled
        idleSafeguardMinutes = s.idleSafeguardMinutes
        plannedStopEnabled = s.plannedStopEnabled
        plannedStopHour = s.plannedStopHour
        plannedStopMinute = s.plannedStopMinute
    }

    private var lastAdjustmentRender = Date.distantPast

    /// Download the star catalog on demand (3c). The download itself runs off-main (CatalogInstaller
    /// .download is nonisolated), so the UI never blocks; progress streams into `catalogState`, and on
    /// success it's applied to the live pipeline via reloadCatalog() so North-up can enable without a
    /// restart. Callable from `.notInstalled` or `.failed` (retry); a no-op while already downloading.
    func downloadCatalog() {
        if case .downloading = catalogState { return }
        catalogState = .downloading(0)
        Task { [weak self] in
            do {
                try await CatalogInstaller.download(progress: { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.catalogState { self?.catalogState = .downloading(p) }
                    }
                })
                self?.catalogState = .installed
                self?.pipeline?.reloadCatalog()
                self?.solveAvailable = self?.pipeline?.hasSolvedWCS ?? false
            } catch {
                self?.catalogState = .failed(Self.catalogErrorText(error))
            }
        }
    }

    private static func catalogErrorText(_ error: Error) -> String {
        switch error {
        case CatalogInstaller.InstallError.checksumMismatch: return "Catalog failed verification — try again."
        case CatalogInstaller.InstallError.invalidCatalog:   return "Downloaded file wasn't a valid catalog."
        case CatalogInstaller.InstallError.http(let code):   return "Download failed (HTTP \(code))."
        default: return "Download failed — check your connection and try again."
        }
    }

    /// Called when a slider changes: persist, push adjustments to the pipeline so
    /// the next frame's snapshot matches, and re-render the current stack off-main
    /// (throttled to ~12 fps so dragging a 26MP stretch stays smooth).
    func applyDisplayAdjustments() {
        saveSettings()
        guard let pipeline else { return }
        let adj = displayAdjustments
        pipeline.displayAdjustments = adj
        let now = Date()
        guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else {
            return   // throttle re-render only; the pipeline state was already updated above
        }
        lastAdjustmentRender = now
        Task.detached { [weak self] in
            // Swift 6: rebind weak self to an immutable strong let up front — nested
            // @Sendable closures may not reference a captured *var* (a weak binding).
            // Lifetime extension is task-scoped (one-shot render); no retain cycle.
            guard let self else { return }
            let cg = pipeline.renderCurrentDisplay(adjustments: adj)
            await MainActor.run {
                guard let cg else { return }
                self.latestImage = cg
            }
        }
    }

    private func makeStackEngine() -> StackEngine {
        let rejection: RejectionMethod = rejectionEnabled
            ? WinsorizedSigmaClip(kappa: rejectionStrength.kappa)
            : NoRejection()
        return StackEngine(rejection: rejection, frameWeighting: frameWeightingEnabled,
                           normalization: backgroundNormalizationEnabled,
                           scaleNormalization: scaleNormalizationEnabled,
                           demosaic: demosaic)
    }

    /// Root for all session output; every session/import directory lives under here.
    static let sessionRootName = "LiveAstro"
    var liveAstroRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.sessionRootName, isDirectory: true)
    }

    var profile: SessionProfile {
        SessionProfile(targetName: targetName, telescope: telescope, camera: camera,
                       mount: mount, filter: filter, locationLabel: locationLabel,
                       bortle: Int(bortleText), subExposureSeconds: Double(subExposureText) ?? 60,
                       notes: notes)
    }

    var integrationCaption: String {
        guard let rec = latestRecord else { return "waiting for first stack…" }
        return IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                                         subSeconds: profile.subExposureSeconds)
    }

    /// Resolve the session's calibration by reading a representative sub already in
    /// the watch folder, auto-matching a master dark/bias from the library (scaling
    /// by exposure when needed), and building the session flat. Returns the Calibrator
    /// (nil if nothing applies) plus log lines.
    ///
    /// Peek-at-Start: real captures (ASIAIR/Seestar/NINA) have subs present at Start.
    /// A session begun on an EMPTY folder can't be matched yet — that's logged and left
    /// uncalibrated (resolve-on-first-sub is a documented follow-up). Not CI-testable
    /// (FileManager + pipeline); the pure matcher/scaler/library are unit-tested.
    func resolveCalibration(watchFolder: URL, prefix: String?)
        -> (calibrator: Calibrator?, messages: [String], foundMetadata: Bool) {
        // Peek a representative sub already in the folder. If none (empty-folder live
        // start), report foundMetadata: false so the caller attaches the first-sub
        // provider instead — calibration then resolves as the first sub lands.
        guard let meta = representativeMetadata(in: watchFolder, prefix: prefix) else {
            calibrationStatus = statusLine(dark: false, flat: false)
            return (nil, ["Calibration: no subs yet — matching from the first sub as it arrives."], false)
        }
        let r = CalibrationResolver.resolve(
            metadata: meta, library: calibrationLibrary, scaleEnabled: scaleDarksAcrossExposures,
            flatsFolder: sessionFlatsFolder, darkFlatsFolder: sessionDarkFlatsFolder,
            legacyDarkPath: calibration.darkPath, legacyFlatPath: calibration.flatPath)
        calibrationStatus = statusLine(dark: r.hasDark, flat: r.hasFlat)
        return (r.calibrator, r.messages, true)
    }

    /// First-sub calibrator provider for empty-folder starts: the pipeline calls this
    /// with the first frame's header on the consume task; it resolves calibration and
    /// hops to the main actor to log + update the status line.
    private func makeCalibratorProvider() -> ((SourceMetadata) -> Calibrator?) {
        let library = calibrationLibrary
        let scale = scaleDarksAcrossExposures
        let flats = sessionFlatsFolder, darkFlats = sessionDarkFlatsFolder
        let legacyDark = calibration.darkPath, legacyFlat = calibration.flatPath
        return { [weak self] meta in
            let r = CalibrationResolver.resolve(
                metadata: meta, library: library, scaleEnabled: scale,
                flatsFolder: flats, darkFlatsFolder: darkFlats,
                legacyDarkPath: legacyDark, legacyFlatPath: legacyFlat)
            DispatchQueue.main.async {
                guard let self else { return }
                r.messages.forEach { self.log.append($0) }
                self.calibrationStatus = self.statusLine(dark: r.hasDark, flat: r.hasFlat)
            }
            return r.calibrator
        }
    }


    private func representativeMetadata(in folder: URL, prefix: String?) -> SourceMetadata? {
        var files = CalibrationLibrary.fitsFiles(in: folder)
        if let prefix, !prefix.isEmpty { files = files.filter { $0.lastPathComponent.hasPrefix(prefix) } }
        for url in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {   // newest first
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            guard let head = try? fh.read(upToCount: 256 * 1024),   // header only, not pixels
                  let header = try? FITSReader.readHeader(head) else { continue }
            return SourceMetadata(fitsKeywords: header.keywords)
        }
        return nil
    }


    private func statusLine(dark: Bool, flat: Bool) -> String {
        switch (dark, flat) {
        case (true, true):  return "Calibrating with dark + flat ✓"
        case (true, false): return "Calibrating with dark ✓"
        case (false, true): return "Calibrating with flat ✓"
        case (false, false):
            // Gentle, actionable — a raw stack looks noisy without calibration, and that's
            // often mistaken for the app rather than missing darks/flats.
            return libraryEntries.isEmpty
                ? "No calibration — add darks/bias to the library for a cleaner stack"
                : "No calibration applied"
        }
    }

    // MARK: - Calibration library management

    func refreshLibraryEntries() { libraryEntries = calibrationLibrary.all() }

    /// Build a master (dark or bias) from a folder of raw frames, keyed automatically
    /// from the first frame's FITS header, and add it to the library. Off the main thread.
    func addMasterFromFolder(_ folder: URL, kind: MasterKind) {
        let urls = CalibrationLibrary.fitsFiles(in: folder)
        guard !urls.isEmpty else { log.append("Calibration: no FITS frames in that folder."); return }
        calibrationBusy = true
        log.append("Calibration: building \(kind.rawValue) master from \(urls.count) frames…")
        let lib = calibrationLibrary
        Task.detached { [weak self] in
            // Swift 6: rebind weak self to a strong immutable up front — nested
            // @Sendable closures may not reference a captured weak *var*.
            guard let self else { return }
            // Key the master from the first READABLE frame's header — not urls[0], which may be the
            // corrupt/unreadable file MasterBuilder silently skips. Keying off a skipped file would
            // stamp the master with generic/nil camera+gain so it never matches lights later.
            var meta = SourceMetadata()
            for url in urls {
                guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? fh.close() }
                if let head = try? fh.read(upToCount: 256 * 1024),
                   let header = try? FITSReader.readHeader(head) {
                    meta = SourceMetadata(fitsKeywords: header.keywords)
                    break
                }
            }
            do {
                let frame = try lib.add(kind: kind, camera: meta.instrument ?? "Camera",
                    gain: meta.gain, exposureSeconds: kind == .bias ? nil : meta.exposureSeconds,
                    // Store only the controlled SET-TEMP as the master's setpoint. CCD-TEMP (actual,
                    // uncontrolled) must not masquerade as a setpoint — that made uncooled darks carry
                    // a spurious temperature that then false-rejected uncooled lights.
                    setTempC: meta.setTempC, binning: meta.binning, fitsURLs: urls)
                await MainActor.run {
                    self.calibrationBusy = false
                    self.refreshLibraryEntries()
                    self.log.append("Calibration: added \(frame.camera) \(kind.rawValue).")
                }
            } catch {
                await MainActor.run {
                    self.calibrationBusy = false
                    self.log.append("Calibration: build failed — \(error.localizedDescription)")
                }
            }
        }
    }

    func removeMaster(_ id: UUID) {
        try? calibrationLibrary.remove(id: id)
        refreshLibraryEntries()
    }

    func rebuildMaster(_ id: UUID) {
        calibrationBusy = true
        let lib = calibrationLibrary
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: strong immutable for nested closures
            let message: String
            do { try lib.rebuild(id: id); message = "Calibration: rebuilt master." }
            catch { message = "Calibration: rebuild failed — \(error.localizedDescription)" }
            await MainActor.run {
                self.calibrationBusy = false
                self.refreshLibraryEntries()
                self.log.append(message)
            }
        }
    }

    /// A one-line description of a library entry for the list UI.
    func summary(of f: MasterFrame) -> String {
        // Int(_:) traps on a finite-but-huge Double (corrupt index value); Int(exactly:) is safe.
        func intStr(_ v: Double) -> String { Int(exactly: v.rounded()).map(String.init) ?? String(format: "%.2g", v) }
        var parts: [String] = [f.camera, f.kind.rawValue]
        if let e = f.exposureSeconds { parts.append("\(intStr(e))s") }
        if let g = f.gain { parts.append("gain \(intStr(g))") }
        if let t = f.setTempC { parts.append("\(intStr(t))°C") }
        if let b = f.binning { parts.append("bin\(b)") }
        return parts.joined(separator: " · ") + " · ×\(f.frameCount)"
    }

    /// Starts a live session watching `watchFolder`.
    /// Not unit-testable: needs FileManager, a live pipeline, and a real watch
    /// folder — the end-to-end test covers this path.
    func startSession() {
        saveSettings()
        guard !isRunning else { return }
        guard !importer.isImporting else { errorMessage = "Finish the import before starting a session."; return }
        guard let folder = watchFolder else { errorMessage = "Pick a watch folder first."; return }
        zoomPan = .fit
        let root = liveAstroRoot

        let p: SessionPipeline
        switch sourceMode {
        case .stackerOutput:
            p = SessionPipeline(watchFolder: folder, profile: profile, rootDirectory: root,
                               fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix,
                               neutralizeBackground: neutralizeBackground)
        case .nativeStack:
            let source = FolderFrameSource(folder: folder, mode: .live,
                                            fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix)
            let engine = makeStackEngine()
            let cal = resolveCalibration(
                watchFolder: folder, prefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix)
            cal.messages.forEach { log.append($0) }
            CalibrationStore.save(calibration, to: .standard)
            // Empty folder at Start → resolve calibration from the first sub that lands.
            let provider = cal.foundMetadata ? nil : makeCalibratorProvider()
            p = SessionPipeline(nativeSource: source, engine: engine, profile: profile,
                rootDirectory: root, neutralizeBackground: neutralizeBackground,
                calibrator: cal.calibrator, calibratorProvider: provider)
            // Pin the session's own subs folder + prefix so a later re-stack lists THEM,
            // not whatever the operator has since changed the live controls to (Fix 4).
            restackSourceDir = folder
            restackPrefix = fileNamePrefix
        }
        p.displayAdjustments = displayAdjustments

        acceptedCount = 0
        rejectedCount = 0
        subFrames = []
        sessionCalibrator = nil   // captured at end() from the pipeline's effectiveCalibrator (Fix 1)

        // Reset per-session completion state and ask for notification permission
        // once (no-op if already granted/denied). The tick starts only on success.
        completionDriver = SessionCompletionDriver()
        lastAcceptedFrame = nil
        notifier.requestAuthorizationIfNeeded()

        // Every accepted frame feeds scene automation (resets the stall clock,
        // switches back to the stack scene if we were showing scope-due-to-stall)
        // and re-arms the idle safeguard via `lastAcceptedFrame`. The `onAccepted`
        // hook fires for every accepted update in both modes; only nativeStack
        // bumps the displayed acceptedCount (see acceptedCount doc).
        let onAccepted: @MainActor () -> Void
        if sourceMode == .nativeStack {
            onAccepted = { [weak self] in
                self?.acceptedCount += 1
                self?.lastAcceptedFrame = Date()
                self?.broadcast.frameAccepted()
            }
        } else {
            onAccepted = { [weak self] in
                self?.lastAcceptedFrame = Date()
                self?.broadcast.frameAccepted()
            }
        }
        wireCallbacks(to: p, onAccepted: onAccepted)
        do {
            try p.start()
            pipeline = p
            isRunning = true
            selectedTab = .live
            sessionStart = Date()
            sessionEnd = nil
            replayURL = nil
            log.append("Session started — watching \(folder.path)")
            broadcast.sessionDidStart(subExposureSeconds: profile.subExposureSeconds)
            startCompletionTick()
        } catch {
            errorMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    /// Starts a finite local demo stream and watches it as an external stacker
    /// output. This is intentionally app-layer orchestration over the normal
    /// stacker-output path: the watcher, snapshot, replay, and output surfaces
    /// are exactly the same ones a Siril-style live stack uses.
    func startDemoSession() {
        guard !isRunning else { return }
        guard !importer.isImporting else {
            errorMessage = "Finish the import before starting the demo."
            return
        }

        let folder = liveAstroRoot.appendingPathComponent("DemoInput", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create demo folder: \(error.localizedDescription)"
            return
        }

        demoTask?.cancel()
        // Snapshot the user's real settings so ending the demo restores them — the
        // demo must leave no "Demo Nebula"/30 s branding, and no DemoInput folder /
        // stacker-output mode / demo prefix, on a later real session or in saved
        // settings (see metadataBeforeDemo, saveSettings, endSession). Captured
        // BEFORE the overrides below.
        metadataBeforeDemo = DemoMetadataSnapshot(
            targetName: targetName, telescope: telescope, camera: camera, mount: mount,
            filter: filter, locationLabel: locationLabel, bortleText: bortleText,
            subExposureText: subExposureText, notes: notes,
            sourceMode: sourceMode, watchFolder: watchFolder, fileNamePrefix: fileNamePrefix)
        sourceMode = .stackerOutput
        watchFolder = folder
        fileNamePrefix = SourceMode.stackerOutput.defaultFileNamePrefix
        targetName = "Demo Nebula"
        telescope = "Demo Stack Generator"
        camera = "Synthetic FITS"
        mount = "Demo"
        filter = "Synthetic luminance"
        locationLabel = "No-sky demo"
        bortleText = ""
        subExposureText = "30"
        notes = "Generated by LiveAstro Try Demo."
        log.append("Try Demo — writing sample stack updates to \(folder.path)")

        startSession()
        guard isRunning else {
            // Session didn't start (e.g. an import is running) — undo the demo override
            // so it doesn't leave "Demo Nebula"/DemoInput branding armed on the real fields.
            restoreMetadataAfterDemoIfNeeded()
            return
        }

        let args = ["demo-stack", folder.path, "--interval", "3", "--count", "30"]
        demoTask = Task.detached { [weak self] in
            guard let model = self else { return }
            do {
                try DemoStackGenerator.run(
                    arguments: args,
                    programName: "demo-stack",
                    shouldContinue: { !Task.isCancelled })
                await MainActor.run {
                    model.log.append("Try Demo generator finished — click End Session when ready.")
                    model.demoTask = nil
                }
            } catch {
                await MainActor.run {
                    model.log.append("Try Demo generator failed: \(error.localizedDescription)")
                    model.demoTask = nil
                }
            }
        }
    }

    /// Wires the pipeline callbacks shared by live sessions and imports.
    /// `onAnyFrame` runs synchronously on the pipeline's callback thread for
    /// every produced frame (accepted or rejected); `onAccepted` runs on the
    /// main actor alongside the model updates for each accepted frame.
    private func wireCallbacks(to pipeline: SessionPipeline,
                               onAccepted: (@MainActor () -> Void)? = nil,
                               onAnyFrame: (() -> Void)? = nil) {
        solveAvailable = false   // new session/pipeline: no solve yet — don't carry a stale gate over
        pipeline.onUpdate = { [weak self] image, record in
            onAnyFrame?()
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
                self?.solveAvailable = self?.pipeline?.hasSolvedWCS ?? false   // gate the North-up toggle
                onAccepted?()
                self?.log.append("✓ update \(record.index) — \(record.snapshotFile)")
            }
        }
        pipeline.onRejected = { [weak self] reason, name in
            onAnyFrame?()
            Task { @MainActor in
                self?.rejectedCount += 1
                self?.log.append("✗ rejected \(name): \(reason)")
            }
        }
        pipeline.onLog = { [weak self] message in
            Task { @MainActor in self?.log.append("⚠ \(message)") }
        }
        // Watcher detection stalled (a hung folder read froze the poll queue) — make it loud:
        // a system notification for an away/asleep operator, plus a visible error so it can't
        // be missed. The loud "Watcher STALLED" line is already in the log via onLog above.
        pipeline.onStall = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.notifier.notifyStall()
                self.errorMessage = "Capture detection stalled — new subs aren't being detected. "
                    + "End and restart the session (a folder read appears to be hung)."
            }
        }
        // Solve state changes off the hot path and emits no display update — refresh the toggle gate on
        // BOTH edges: a solve landing (enable) and a reseed/auto-reseed invalidating it (disable).
        pipeline.onSolveStateChanged = { [weak self] in
            Task { @MainActor in self?.solveAvailable = self?.pipeline?.hasSolvedWCS ?? false }
        }
        // Task 8a data plane: mirror each persisted sub onto the main actor for the Stats
        // UI. The pipeline already wrote the record to session.subFrames on its own
        // callback thread (SessionPipeline.handleNative) — this hop is UI-mirror only.
        pipeline.onSubFrame = { [weak self] record in
            Task { @MainActor in self?.subFrames.append(record) }
        }
    }

    /// Number of subs the operator has flagged for exclusion from a re-stack.
    var flaggedCount: Int { subFrames.filter(\.rejectedByUser).count }

    /// Flips the operator reject flag on the in-memory mirror for the sub with `index`.
    /// During a LIVE session this is mirror-only — writing mid-session would race the
    /// pipeline's consume task. Once the session has FINISHED (`!isRunning`), there is no
    /// consume task, so the flip is persisted to `sub-frames.csv` IMMEDIATELY — this keeps
    /// the Siril review workflow (flag → export CSV → reject in Siril, never re-stack) and a
    /// subsequent quit truthful. Flags persist to sub-frames.csv, NEVER to the manifest
    /// (whose per-sub `rejectedByUser` is always the record-time value, false). Refused while
    /// a re-stack is in flight, so a toggle can't desync the master from the CSV (Fix 5).
    func toggleReject(index: Int) {
        guard !isRestacking else { return }
        guard let i = subFrames.firstIndex(where: { $0.index == index }) else { return }
        subFrames[i].rejectedByUser.toggle()
        if !isRunning, let dir = lastSessionDirectory {
            try? SubFrameCSV.write(subFrames: subFrames, to: dir)   // keep sub-frames.csv truthful during review
        }
    }

    /// Rebuilds the master from the session's raw subs, excluding every sub the
    /// operator has flagged, and applies the result (Task 8b). Post-capture only
    /// (`!isRunning`, per Task 8 Refinement) — a live pipeline's display would just
    /// overwrite a mid-session restack on the next frame, and this avoids concurrent
    /// writers on the master/manifest.
    ///
    /// The re-stack uses the CURRENT stacking settings (rejection / weighting /
    /// normalization / demosaic) via `makeStackEngine()`, so changing those after capture
    /// changes the integration relative to the live master — intended for now.
    func restackWithoutFlagged() {
        guard !isRunning else { return }
        guard !isRestacking else { return }
        guard flaggedCount > 0 else {
            log.append("Re-stack skipped — no subs are flagged.")
            return
        }
        // Use the folder/prefix captured at session START, not the live-mutable controls —
        // the operator may have changed watchFolder/fileNamePrefix (or source mode) after End
        // but before Re-stack (Fix 4).
        guard let dir = restackSourceDir else {
            log.append("Re-stack unavailable — the raw subs folder is unknown.")
            return
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        } catch {
            log.append("Re-stack unavailable — couldn't read the raw subs folder: \(error)")
            return
        }
        let prefix = restackPrefix.lowercased()
        let urls = entries
            .filter { ImageLoader.fitsExtensions.contains($0.pathExtension.lowercased()) }
            // Match the session's file-name prefix, same as live (StackFileWatcher.
            // isTrackedFileName) and import (ImportCursor) — otherwise the survivor set
            // wrongly includes other-filter/foreign/calibration FITS sitting in the same
            // folder (Fix C). Empty prefix accepts all, matching existing semantics.
            .filter { restackPrefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            // Drop dotfiles and .tmp sidecars, matching StackFileWatcher.isTrackedFileName —
            // an in-flight atomic write (".foo.fit.tmp") must never enter the survivor set (Fix 5).
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasSuffix(".tmp") }
            // Numeric-aware order so Light_2 precedes Light_10 (capture sequence order) —
            // matches FolderFrameSource, so the first surviving frame (the stack's seed)
            // is the same one the live pipeline would have chosen.
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending }
        guard !urls.isEmpty else {
            log.append("Re-stack unavailable — no raw subs found on disk (they may have been pruned).")
            return
        }

        let excluded = Set(subFrames.filter(\.rejectedByUser).map(\.sourceFile))
        let excludedCount = excluded.count

        // Reuse the EXACT calibrator the live pipeline applied before stacking (captured in
        // endSession as effectiveCalibrator — explicit or first-frame auto-resolved), NOT a
        // rebuild from legacy config paths (usually nil → an uncalibrated master would silently
        // overwrite the good one). A nil sessionCalibrator (uncalibrated session) yields an
        // identity prepare. Calibrator.apply is NSLock-guarded, safe off the main actor (Fix 1).
        // restackOfferPending stays set until the re-stack SUCCEEDS (cleared in
        // applyRestackedMaster), so a failed re-stack leaves the offer up for retry (Fix 5).
        isRestacking = true
        let engine = makeStackEngine()
        Task.detached { [weak self, sessionCalibrator] in
            guard let self else { return }
            do {
                let report = try RestackCoordinator.restack(
                    rawURLs: urls, excludingSourceFiles: excluded, makeEngine: { engine },
                    prepare: { sessionCalibrator?.apply($0) ?? $0 })
                await MainActor.run { self.applyRestackedMaster(report, excludedCount: excludedCount) }
            } catch {
                await MainActor.run {
                    self.log.append("Re-stack failed: \(error). Master unchanged.")
                    self.isRestacking = false
                }
            }
        }
    }

    /// Applies a completed re-stack: writes the rebuilt master over `master.fit` (if the
    /// session directory is known), refreshes the on-screen preview, and logs the outcome.
    ///
    /// v1 preview limitation: `AutoStretch.makeCGImage` is a basic stretch only — it does
    /// NOT run the live DisplayAdjustments/DBE/denoise/north-up pipeline (that lives on
    /// `SessionPipeline`, which has already ended by the time a restack is offered). The
    /// durable deliverable is the corrected `master.fit`; the on-screen preview is a
    /// basic-stretch confirmation that the restack happened, not a faithful re-render of
    /// the operator's display settings.
    private func applyRestackedMaster(_ report: RestackReport, excludedCount: Int) {
        if let sessionDirectory = lastSessionDirectory {
            do {
                try MasterBuilder.save(report.master, to: sessionDirectory.appendingPathComponent("master.fit"))
            } catch {
                log.append("Re-stack: could not write master.fit (\(error)).")
            }
            // Re-write sub-frames.csv from the in-memory mirror so it reflects the operator's
            // flags at re-stack time — the manifest's persisted records were written before
            // flagging (rejectedByUser = false at persist time), so this is the accurate copy.
            do {
                try SubFrameCSV.write(subFrames: subFrames, to: sessionDirectory)
            } catch {
                log.append("Re-stack: could not write sub-frames.csv (\(error)).")
            }
        } else {
            log.append("Re-stack: no session directory on record — master.fit was not written.")
        }
        if let cg = AutoStretch.makeCGImage(report.master) {
            latestImage = cg
        }
        if report.skippedMissing > 0 {
            log.append("Re-stack: \(report.skippedMissing) raw sub(s) missing — used the rest.")
        }
        log.append("Re-stacked without \(excludedCount) flagged sub(s): \(report.stackedCount) frames.")
        // Clear the offer only now, on the SUCCESS path — a failed re-stack (handled in the
        // detached task's catch) leaves restackOfferPending up so the operator can retry (Fix 5).
        restackOfferPending = false
        isRestacking = false
    }

    /// Reseeds the stacking engine reference frame (native mode only).
    func reseedReference() {
        guard isRunning && sourceMode == .nativeStack else { return }
        guard !importer.isGeneratingReplay else {
            log.append("reseed refused — session finalization has begun")
            return
        }
        switch pipeline?.reseed() {
        case .reseeded?: log.append("reference reseeded")
        case .unavailableDuringImport?: log.append("reseed unavailable while an import is running")
        case .finalizationInProgress?: log.append("reseed refused — session finalization has begun")
        case .finalizationRetryPending?: log.append("reseed refused — session finalization failed; retry End Session before reseeding")
        case .notNative?, nil: log.append("reseed unavailable — no native stack is active")
        }
    }

    /// Polls the completion driver every 30 s while the session runs. The tick is
    /// generation/teardown-guarded: after each sleep it re-checks `isRunning` and
    /// cancellation, so a fired action can never land after the session already
    /// ended. On `.safeguard` it writes a master snapshot (idle safeguard KEEPS the
    /// session live — it never ends it); on `.endSession` it routes to the existing
    /// `endSession()` finalize (no parallel path) and stops ticking. Neither branch
    /// quits the app or stops the broadcast directly.
    private func startCompletionTick() {
        completionTick?.cancel()
        completionTick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30 s
                guard let self, self.isRunning, !Task.isCancelled else { return }
                let action = self.completionDriver.step(
                    now: Date(), plannedStopAnchor: self.plannedStopAnchor,
                    lastAcceptedFrame: self.lastAcceptedFrame,
                    settings: self.currentSettings().completionSettings)
                switch action {
                case .safeguard:
                    // Idle safeguard is native-only (writeMasterSnapshot() can only
                    // snapshot a native stack). In watcher/mirror mode the external
                    // stacker owns its master, so skip and leave the fired flag set —
                    // don't retry a pointless snapshot every 30 s. The UI gate is the
                    // primary fix; this is belt-and-suspenders.
                    if self.sourceMode != .nativeStack { break }
                    // Idle capture: persist a master snapshot but keep running. If
                    // the snapshot could not be written (a failed write), clear the
                    // flag so it retries on the next tick rather than being silently
                    // consumed.
                    if self.pipeline?.writeMasterSnapshot() == true {
                        self.notifier.notifySafeguard()
                    } else {
                        self.completionDriver.clearSafeguardForRetry()
                    }
                case .endSession:
                    self.notifier.notifyPlannedStopEnd()
                    self.endSession()   // existing full finalize; also cancels this tick
                    return
                case .none:
                    break
                }
            }
        }
    }

    func endSession() {
        restoreMetadataAfterDemoIfNeeded()   // undo demo branding before it can be persisted
        saveSettings()
        completionTick?.cancel()
        completionTick = nil
        guard let p = pipeline else { return }
        guard !importer.isGeneratingReplay else { return }
        importer.isGeneratingReplay = true
        log.append("Ending session — generating replay…")

        // Stop the relay (if any) immediately — before the pipeline drains.
        liveSource.stopRelay()
        demoTask?.cancel()

        // Immediate part only: scene automation stops and live broadcast state
        // resets at the click. The OBS stream/record stop is deferred to
        // stopBroadcastAfterSessionEnd() below — strictly after p.end() returns
        // or throws — matching the README: "End Session runs the replay
        // generation first, then — and only then — stops the OBS stream and
        // recording" (review4 P2: previously the stop Task fired here, racing
        // the detached replay task).
        broadcast.sessionDidEnd()

        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            let shouldCompleteSession: Bool
            do {
                let url = try p.end()
                await MainActor.run {
                    self.replayURL = url
                    self.lastSessionDirectory = url.deletingLastPathComponent()
                    self.log.append("Replay ready: \(url.lastPathComponent)")
                    // Overwrite the Core-written sub-frames.csv (rejectedByUser=false at
                    // persist time — Core has no durable flag-setter, see Fix D) with one
                    // reflecting the AppModel mirror's operator flags. Post-drain, main
                    // actor: race-free against the pipeline's consume task.
                    if !self.subFrames.isEmpty, let dir = self.lastSessionDirectory {
                        try? SubFrameCSV.write(subFrames: self.subFrames, to: dir)
                    }
                }
                shouldCompleteSession = true
            } catch {
                shouldCompleteSession = await MainActor.run {
                    if p.session.state == .running {
                        // Core finalization failed before the manifest commit point (for example:
                        // master.fit or manifest persistence could not complete). The End Session
                        // click has already stopped relay/scene-automation side effects, but the
                        // durable finalization itself is deliberately still retryable through the
                        // same pipeline; dropping it here would turn an honest retryable failure
                        // into an unrecoverable UI lie.
                        self.errorMessage = "End Session failed: \(error)"
                        self.log.append("End Session failed before final commit — finalization remains retryable; fix the error and try End Session again")
                        self.importer.isGeneratingReplay = false
                        return false
                    }
                    self.errorMessage = "Replay failed: \(error)"
                    // The session DID commit (manifest + master.fit persisted); only the replay
                    // render failed. The success path's lastSessionDirectory update + flag-CSV
                    // write live in the `do` block we skipped, so do them here too — otherwise a
                    // committed session ends with a stale/nil lastSessionDirectory and an all-false
                    // sub-frames.csv (Fix 3). Use the committed session's own directory.
                    if let dir = p.sessionDir {
                        self.lastSessionDirectory = dir
                        if !self.subFrames.isEmpty {
                            try? SubFrameCSV.write(subFrames: self.subFrames, to: dir)
                        }
                    }
                    return true
                }
            }
            guard shouldCompleteSession else { return }
            await MainActor.run {
                self.isRunning = false
                self.importer.isGeneratingReplay = false
                // Stash the calibrator the pipeline ACTUALLY applied (explicit or first-frame
                // auto-resolved) BEFORE releasing the pipeline, so a post-session re-stack reuses
                // the exact same calibration the live master used (Fix 1).
                self.sessionCalibrator = p.effectiveCalibrator
                self.pipeline = nil
                self.sessionEnd = Date()
                self.restackOfferPending = self.flaggedCount > 0
                // Common completion (success OR replay failure): only now stop
                // the OBS stream/recording — a failed replay must still stop
                // the stream, so this lives here, not on the success path.
                self.broadcast.stopBroadcastAfterSessionEnd()
            }
        }
    }

    // MARK: - Session Health summary text
    //
    // Single home for these formatters — previously duplicated between ControlView's
    // "Copy Support Bundle" footer action and DiagnosticsView's Session Health grid.
    // Both views reference these directly off the model.

    var sessionStateText: String {
        if liveSource.isDetecting { return "Detecting source" }
        if importer.isImporting { return "Importing" }
        if importer.isGeneratingReplay { return "Rendering replay" }
        if isRunning { return "Running" }
        return "Idle"
    }

    var sourceSummaryText: String {
        switch sourceMode {
        case .nativeStack:
            return "Native stacking"
        case .stackerOutput:
            return "Siril / external stacker"
        }
    }

    var watchFolderSummaryText: String {
        watchFolder?.path ?? "(none selected)"
    }

    var lastUpdateSummaryText: String {
        guard let record = latestRecord else { return integrationCaption }
        return "#\(record.index) · \(record.snapshotFile)"
    }

    var framesSummaryText: String {
        "accepted \(acceptedCount) · rejected \(rejectedCount)"
    }

    var lastRejectionSummaryText: String {
        guard let line = log.last(where: { $0.hasPrefix("✗ rejected ") }) else {
            return "(none)"
        }
        let prefix = "✗ rejected "
        if line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    var obsSummaryText: String {
        switch broadcast.broadcastState {
        case .idle:
            return "idle"
        case .unknown:
            return "not checked"
        case .connecting:
            return "connecting"
        case .live:
            if let h = broadcast.streamHealth {
                return "live · \(formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% congestion"
            }
            return "live"
        case .endingSession:
            return "ending session"
        case .stopping:
            return "stopping"
        case .stopUnconfirmed:
            return "may still be live"
        }
    }

    var outputsSummaryText: String {
        if replayURL != nil { return "replay ready" }
        if lastSessionDirectory != nil { return "session folder ready" }
        return "no finished session yet"
    }

    func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    // MARK: - Folder pickers
    //
    // Single home for these — previously duplicated between ControlView's pinned
    // footer and CaptureSettingsView's Start Workflow / Watch Folder sections.

    func makeDirectoryPanel(title: String? = nil, message: String? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let title { panel.title = title }
        if let message { panel.message = message }
        return panel
    }

    func pickNativeWatchFolderLive() {
        pickWatchFolderLive(
            sourceMode: .nativeStack,
            title: "Choose Live FITS Folder",
            message: "Select the folder where NINA, ASIAIR, or another capture app writes new FITS light frames."
        )
    }

    func pickWatchFolderLive(sourceMode: AppModel.SourceMode,
                              title: String,
                              message: String) {
        let panel = makeDirectoryPanel(title: title, message: message)
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            self.sourceMode = sourceMode
            self.liveSource.startWatchFolderLive(source: url, sourceMode: sourceMode)
        }
    }

    func pickImportFolder() {
        let panel = makeDirectoryPanel(title: "Choose Subs Folder",
                                       message: "Select a folder containing raw FITS subs to import")
        if panel.runModal() == .OK, let url = panel.url {
            importer.importSubs(from: url)
        }
    }
}
