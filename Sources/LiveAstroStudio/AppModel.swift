import SwiftUI
import AppKit
import LiveAstroCore

@Observable
@MainActor
final class AppModel {

    enum MainTab: String, CaseIterable { case live = "Live", setup = "Setup", help = "Help" }
    var selectedTab: MainTab = .setup
    var isDetached = false

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
    var rejectionEnabled = true
    var rejectionStrength: RejectionStrength = .medium
    var frameWeightingEnabled = true
    var backgroundNormalizationEnabled = true
    var scaleNormalizationEnabled = true
    var demosaic: DemosaicMethod = .rcd
    var calibration = CalibrationStore.load(.standard)
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
    var isImporting = false
    var isProcessing = false
    /// Accepted frames this session; updated only in .nativeStack mode
    /// (watcher mode reads 0 — use latestRecord?.index instead).
    var acceptedCount = 0
    var rejectedCount = 0
    var latestImage: CGImage?
    var latestRecord: SnapshotRecord?
    var sessionStart: Date?
    var sessionEnd: Date?
    var log: [String] = []
    var replayURL: URL?
    var isGeneratingReplay = false
    var processorBackend: ProcessorBackend = .none
    var displayAdjustments = DisplayAdjustments.neutral
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

    /// OBS / broadcast / scene-automation cluster (T1 extraction). Owned here as
    /// an implicitly-unwrapped `let`-in-spirit: it's assigned exactly once, early
    /// in `init`, before any use — the IUO is only to break the init-order knot
    /// (the `AppSurface` closures capture `self`, so `broadcast` cannot be a
    /// stored `let` initialized in its declaration). Assigned exactly once in
    /// `init` and never reassigned — the `var` (rather than `private(set) var`)
    /// is required only so SwiftUI can form writable bindings through it
    /// (`$model.broadcast.obsHost`); the reference itself is never rebound.
    var broadcast: BroadcastController!

    /// Live-source orchestration cluster (T2 extraction): the frame relay, its
    /// retention policy, and the three auto-detect/configure paths. Same IUO
    /// init-order rationale as `broadcast` above — assigned exactly once early in
    /// `init` (its `AppSurface` closures capture `self`, so it can't be a stored
    /// `let`), never reassigned; `var` only so SwiftUI can bind through it
    /// (`$model.liveSource.relayRetentionDays`).
    var liveSource: LiveSourceController!

    var importProcessed = 0
    var importTotal = 0
    private var pipeline: SessionPipeline?
    private var importPipeline: SessionPipeline?

    init() {
        // Build the seam bundle and the Broadcast controller first. The closures
        // capture `self` (safe: they only fire after init completes), and
        // `broadcast` must exist before loadSettings()/session hooks reference it.
        broadcast = BroadcastController(surface: AppSurface(
            log: { [weak self] message in MainActor.assumeIsolated { self?.log.append(message) } },
            presentError: { [weak self] message in MainActor.assumeIsolated { self?.errorMessage = message } },
            isSessionRunning: { [weak self] in MainActor.assumeIsolated { self?.isRunning ?? false } }))

        // Live-source cluster: same seam, plus the T2 closures for the detect
        // paths (draft writes, tab/zoom, save + start). applyDetectedProfile
        // writes only the non-nil fields — byte-identical to the old inline sets.
        liveSource = LiveSourceController(surface: AppSurface(
            log: { [weak self] message in MainActor.assumeIsolated { self?.log.append(message) } },
            presentError: { [weak self] message in MainActor.assumeIsolated { self?.errorMessage = message } },
            isSessionRunning: { [weak self] in MainActor.assumeIsolated { self?.isRunning ?? false } },
            isImporting: { [weak self] in MainActor.assumeIsolated { self?.isImporting ?? false } },
            applyDetectedProfile: { [weak self] p in MainActor.assumeIsolated { self?.applyDetectedProfile(p) } },
            currentTargetName: { [weak self] in MainActor.assumeIsolated { self?.targetName ?? "" } },
            resetZoomPan: { [weak self] in MainActor.assumeIsolated { self?.zoomPan = .fit } },
            selectLiveTab: { [weak self] in MainActor.assumeIsolated { self?.selectedTab = .live } },
            startSession: { [weak self] in MainActor.assumeIsolated { self?.startSession() } },
            saveSettings: { [weak self] in MainActor.assumeIsolated { self?.saveSettings() } }))
        loadSettings()

        // Save settings and stop the relay when the app is about to terminate.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveSource.stopRelay()
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
            demosaic: demosaic)
    }

    func saveSettings() { SessionSettingsStore.save(currentSettings(), to: .standard) }

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
        displayAdjustments = s.displayAdjustments
    }

    private var lastAdjustmentRender = Date.distantPast

    /// Called when a slider changes: persist, push adjustments to the pipeline so
    /// the next frame's snapshot matches, and re-render the current stack off-main
    /// (throttled to ~12 fps so dragging a 26MP stretch stays smooth).
    func applyDisplayAdjustments() {
        saveSettings()
        guard let pipeline else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else { return }
        lastAdjustmentRender = now
        let adj = displayAdjustments
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

    /// Starts a live session watching `watchFolder`.
    /// Not unit-testable: needs FileManager, a live pipeline, and a real watch
    /// folder — the end-to-end test covers this path.
    func startSession() {
        saveSettings()
        guard !isRunning else { return }
        guard !isImporting else { errorMessage = "Finish the import before starting a session."; return }
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
            let (calibrator, calWarnings) = CalibrationLoader.makeCalibrator(
                dark: calibration.darkPath.map { URL(fileURLWithPath: $0) },
                flat: calibration.flatPath.map { URL(fileURLWithPath: $0) })
            calWarnings.forEach { log.append("⚠ \($0)") }
            CalibrationStore.save(calibration, to: .standard)
            p = SessionPipeline(nativeSource: source, engine: engine, profile: profile,
                               rootDirectory: root, neutralizeBackground: neutralizeBackground,
                               calibrator: calibrator)
        }

        acceptedCount = 0
        rejectedCount = 0

        // Every accepted frame feeds scene automation (resets the stall clock,
        // switches back to the stack scene if we were showing scope-due-to-stall).
        // Watcher mode has no per-frame accept count (see acceptedCount doc), so
        // only nativeStack bumps acceptedCount.
        let onAccepted: @MainActor () -> Void
        if sourceMode == .nativeStack {
            onAccepted = { [weak self] in
                self?.acceptedCount += 1
                self?.broadcast.frameAccepted()
            }
        } else {
            onAccepted = { [weak self] in self?.broadcast.frameAccepted() }
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
        } catch {
            errorMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    /// Wires the pipeline callbacks shared by live sessions and imports.
    /// `onAnyFrame` runs synchronously on the pipeline's callback thread for
    /// every produced frame (accepted or rejected); `onAccepted` runs on the
    /// main actor alongside the model updates for each accepted frame.
    private func wireCallbacks(to pipeline: SessionPipeline,
                               onAccepted: (@MainActor () -> Void)? = nil,
                               onAnyFrame: (() -> Void)? = nil) {
        pipeline.onUpdate = { [weak self] image, record in
            onAnyFrame?()
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
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
    }

    /// Reseeds the stacking engine reference frame (native mode only).
    func reseedReference() {
        guard isRunning && sourceMode == .nativeStack && !isGeneratingReplay else { return }
        pipeline?.reseed()
        log.append("reference reseeded")
    }

    /// Imports raw FITS subs from `folder` as a one-shot batch.
    /// Runs start()+end() off the main thread; end() drains the finite import stream.
    /// Not unit-testable: needs a detached task and a real folder; the
    /// zero-match path is covered via noMatchMessage(prefix:).
    func importSubs(from folder: URL) {
        saveSettings()
        guard !isRunning else { errorMessage = "End the session before importing."; return }
        guard !isImporting else { return }
        // Reflect the imported subs' actual target/exposure in the profile + Live
        // overlay instead of showing stale form values from a prior session (matches
        // the live/auto-detect paths, which fill these from the newest sub's header).
        if let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: folder) {
            if let object = meta.object, !object.isEmpty { targetName = object }
            if let exp = meta.exposureSeconds, exp > 0 { subExposureText = String(format: "%g", exp) }
            saveSettings()
        }
        let source = FolderFrameSource(folder: folder, mode: .importOnce,
                                        fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix)
        let engine = makeStackEngine()
        let (importCalibrator, importCalWarnings) = CalibrationLoader.makeCalibrator(
            dark: calibration.darkPath.map { URL(fileURLWithPath: $0) },
            flat: calibration.flatPath.map { URL(fileURLWithPath: $0) })
        importCalWarnings.forEach { log.append("⚠ \($0)") }
        CalibrationStore.save(calibration, to: .standard)
        let importPipeline = SessionPipeline(nativeSource: source, engine: engine, profile: profile,
                                              rootDirectory: liveAstroRoot,
                                              neutralizeBackground: neutralizeBackground,
                                              calibrator: importCalibrator)
        importPipeline.onImportProgress = { [weak self] processed, total, accepted, rejected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.importProcessed = processed; self?.importTotal = total
                    self?.acceptedCount = accepted; self?.rejectedCount = rejected
                }
            }
        }
        self.importPipeline = importPipeline
        // Counts every frame the source produced (accepted or rejected); it stays at zero
        // only when nothing in the folder matched the prefix at all. The pipeline callbacks
        // fire synchronously on the consume task, which end() drains before returning.
        let matchedFrames = AtomicCounter()
        wireCallbacks(to: importPipeline, onAnyFrame: { matchedFrames.increment() })
        importProcessed = 0
        importTotal = 0
        isImporting = true
        log.append("Importing subs from \(folder.path)…")
        let prefix = fileNamePrefix
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                try importPipeline.start()
                let url = try importPipeline.end()
                await MainActor.run {
                    if matchedFrames.value == 0 {
                        self.errorMessage = AppModel.noMatchMessage(prefix: prefix)
                    } else {
                        self.replayURL = url
                        self.lastSessionDirectory = url.deletingLastPathComponent()
                        self.log.append("Import complete. Replay: \(url.path)")
                    }
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    // A zero-match import may also surface as a downstream failure
                    // (nothing to render) — prefer the actionable message.
                    self.errorMessage = matchedFrames.value == 0
                        ? AppModel.noMatchMessage(prefix: prefix)
                        : "Import failed: \(error)"
                    self.isImporting = false
                }
            }
        }
    }

    func cancelImport() { importPipeline?.cancelImport() }

    /// User-facing message for an import that matched zero files.
    private nonisolated static func noMatchMessage(prefix: String) -> String {
        prefix.isEmpty
            ? "No .fit files found in the chosen folder."
            : "No .fit files matching prefix '\(prefix)' in the chosen folder."
    }

    func regenerateReplay(sessionDirectory: URL) {
        guard !isRunning && !isGeneratingReplay else { return }
        isGeneratingReplay = true
        log.append("Regenerating replay for \(sessionDirectory.lastPathComponent)…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let url = try ReplayService.regenerate(sessionDirectory: sessionDirectory)
                await MainActor.run {
                    self.replayURL = url
                    self.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self.errorMessage = "Regenerate failed: \(error)" }
            }
            await MainActor.run { self.isGeneratingReplay = false }
        }
    }

    func processMaster(sessionDirectory: URL) {
        guard !isProcessing, !isImporting, !isRunning else { return }
        guard processorBackend == .graxpert, let exe = GraXpertProcessor.defaultExecutable() else {
            errorMessage = "GraXpert not found — install it from graxpert.com"; return
        }
        let master = sessionDirectory.appendingPathComponent("master.fit")
        guard FileManager.default.fileExists(atPath: master.path) else {
            errorMessage = "No master.fit in this session — post-processing needs a natively-stacked master (Raw subs mode)."
            return
        }
        isProcessing = true
        log.append("Processing master with GraXpert…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let out = sessionDirectory.appendingPathComponent("master_processed.fit")
                let proc = GraXpertProcessor(executable: exe)
                // process() runs synchronously within this task, so the strong `self`
                // let is safely captured by the progress callback for its duration.
                try proc.process(masterURL: master, outputURL: out) { m in
                    Task { @MainActor in self.log.append(m) }
                }
                await MainActor.run {
                    self.isProcessing = false
                    self.log.append("Processed → \(out.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorMessage = "Processing failed: \(error)"
                }
            }
        }
    }

    func endSession() {
        saveSettings()
        guard let p = pipeline else { return }
        guard !isGeneratingReplay else { return }
        isGeneratingReplay = true
        log.append("Ending session — generating replay…")

        // Stop the relay (if any) immediately — before the pipeline drains.
        liveSource.stopRelay()

        // Scene automation stops immediately, live broadcast state resets, and the
        // deliberate end-of-session OBS stop is issued — all in the controller, at
        // the same point the inline logic fired.
        broadcast.sessionDidEnd()

        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let url = try p.end()
                await MainActor.run {
                    self.replayURL = url
                    self.lastSessionDirectory = url.deletingLastPathComponent()
                    self.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self.errorMessage = "Replay failed: \(error)" }
            }
            await MainActor.run {
                self.isRunning = false
                self.isGeneratingReplay = false
                self.pipeline = nil
                self.sessionEnd = Date()
            }
        }
    }
}
