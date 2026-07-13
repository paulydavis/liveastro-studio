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
    var isDetecting = false
    var rejectionEnabled = true
    var rejectionStrength: RejectionStrength = .medium
    var frameWeightingEnabled = true
    var backgroundNormalizationEnabled = true
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

    // MARK: - OBS

    /// High-level OBS controller (Foundation/Combine, UI-free). Owned here; the
    /// app target does the AppKit-flavored choreography (launch, timers).
    let obs = OBSController()

    // OBS connection config (bound to the settings form).
    var obsHost = "localhost"
    var obsPort = 4455
    var obsPassword = ""
    /// Launch OBS via NSWorkspace if the first connect attempt fails.
    var obsAutoLaunch = true
    /// Also start OBS recording when the stream comes up.
    var obsRecord = false
    /// Master switch for stall-driven scene automation.
    var sceneAutomationOn = false
    /// Scene shown while stacking makes progress (the "hero" view).
    var stackSceneName = ""
    /// Scene shown when imaging stalls (e.g. a live scope/finder view).
    var scopeSceneName = ""

    // MARK: Broadcast state
    enum BroadcastState: Equatable { case idle, connecting, live, stopping }
    var broadcastState: BroadcastState = .idle
    var streamHealth: StreamHealth?
    private var healthPollTask: Task<Void, Never>?
    private var goLiveTask: Task<Void, Never>?

    /// bundle id used to resolve + launch OBS.
    private static let obsBundleID = "com.obsproject.obs-studio"

    // Scene-automation runtime state (nil unless a session + automation is live).
    private var sceneTimer: Timer?
    private var stall: StallDetector?
    /// True while we're showing `scopeSceneName` *because* of a detected stall,
    /// so the accepted-frame hook knows to switch back to the stack scene once.
    private var showingScopeDueToStall = false
    /// Set when the operator changes the program scene by hand (an event we
    /// didn't cause). Suspends automation until the next stall/resume boundary.
    private var manualOverride = false
    /// The scene name automation last requested, so an incoming
    /// CurrentProgramSceneChanged can tell "us" from "the operator".
    private var lastAutomationScene: String?

    var importProcessed = 0
    var importTotal = 0
    private var pipeline: SessionPipeline?
    private var importPipeline: SessionPipeline?
    private var frameRelay: FrameRelay?

    init() {
        // Route OBS diagnostics into the session log. onLog fires on the main
        // actor (OBSController is @MainActor), so appending is safe.
        obs.onLog = { [weak self] message in
            MainActor.assumeIsolated { self?.log.append("OBS: \(message)") }
        }
        loadSettings()

        // Save settings and stop the relay when the app is about to terminate.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.frameRelay?.stop()
                self?.saveSettings()
            }
        }
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
            processorBackend: processorBackend,
            displayAdjustments: displayAdjustments)
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
            let cg = pipeline.renderCurrentDisplay(adjustments: adj)
            await MainActor.run {
                guard let self, let cg else { return }
                self.latestImage = cg
            }
        }
    }

    private func makeStackEngine() -> StackEngine {
        let rejection: RejectionMethod = rejectionEnabled
            ? WinsorizedSigmaClip(kappa: rejectionStrength.kappa)
            : NoRejection()
        return StackEngine(rejection: rejection, frameWeighting: frameWeightingEnabled,
                           normalization: backgroundNormalizationEnabled)
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
                self?.onFrameAccepted()
            }
        } else {
            onAccepted = { [weak self] in self?.onFrameAccepted() }
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
            startSceneAutomation()
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
            do {
                try importPipeline.start()
                let url = try importPipeline.end()
                await MainActor.run {
                    if matchedFrames.value == 0 {
                        self?.errorMessage = AppModel.noMatchMessage(prefix: prefix)
                    } else {
                        self?.replayURL = url
                        self?.lastSessionDirectory = url.deletingLastPathComponent()
                        self?.log.append("Import complete. Replay: \(url.path)")
                    }
                    self?.isImporting = false
                }
            } catch {
                await MainActor.run {
                    // A zero-match import may also surface as a downstream failure
                    // (nothing to render) — prefer the actionable message.
                    self?.errorMessage = matchedFrames.value == 0
                        ? AppModel.noMatchMessage(prefix: prefix)
                        : "Import failed: \(error)"
                    self?.isImporting = false
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
            do {
                let url = try ReplayService.regenerate(sessionDirectory: sessionDirectory)
                await MainActor.run {
                    self?.replayURL = url
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Regenerate failed: \(error)" }
            }
            await MainActor.run { self?.isGeneratingReplay = false }
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
            do {
                let out = sessionDirectory.appendingPathComponent("master_processed.fit")
                let proc = GraXpertProcessor(executable: exe)
                try proc.process(masterURL: master, outputURL: out) { [weak self] m in
                    Task { @MainActor in self?.log.append(m) }
                }
                await MainActor.run {
                    self?.isProcessing = false
                    self?.log.append("Processed → \(out.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self?.isProcessing = false
                    self?.errorMessage = "Processing failed: \(error)"
                }
            }
        }
    }

    func startWatchFolderLive(source: URL) {
        guard !isRunning, !isImporting, !isDetecting else { return }
        zoomPan = .fit
        isDetecting = true
        log.append("Reading subs in \(source.lastPathComponent)…")
        Task.detached { [weak self] in
            let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: source)   // SMB header read, off main
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                self.configureAndStartWatchFolder(source: source, meta: meta)
            }
        }
    }

    private func configureAndStartWatchFolder(source: URL,
                                              meta: (object: String?, exposureSeconds: Double?, fileExtension: String)?) {
        sourceMode = .nativeStack
        neutralizeBackground = true
        if let object = meta?.object, !object.isEmpty { targetName = object }        // else keep form value
        if let exp = meta?.exposureSeconds, exp > 0 { subExposureText = String(format: "%g", exp) }
        let target = targetName.isEmpty ? "Live" : targetName
        let glob = "*.\(meta?.fileExtension ?? "fit")"       // *.fit or *.fits per the folder's subs
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(target)-\(df.string(from: Date()))", isDirectory: true)
        let relay = FrameRelay(source: source, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in Task { @MainActor in self?.log.append(msg) } }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        frameRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()
        if !isRunning { frameRelay?.stop(); frameRelay = nil; return }
        selectedTab = .live
    }

    func startSeestarLive() {
        guard !isRunning, !isImporting, !isDetecting else { return }
        zoomPan = .fit
        isDetecting = true
        log.append("Looking for Seestar share…")
        Task.detached { [weak self] in
            let found = SeestarDetector.detect()      // SMB directory work, off the main thread
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                guard let found else {
                    self.errorMessage = "No Seestar share found. Mount it first: Finder → Go → Connect to Server → the Seestar's smb:// address, then try again."
                    return
                }
                self.configureAndStartSeestar(found)
            }
        }
    }

    /// The on-main configure + start body (unchanged from the old synchronous
    /// startSeestarLive, from `found` onward). Runs on the main actor.
    private func configureAndStartSeestar(_ found: SeestarDetector.Found) {
        sourceMode = .nativeStack
        fileNamePrefix = "Light_"
        neutralizeBackground = true
        targetName = found.target
        let exp = found.subExposure
        subExposureText = String(format: "%g", exp ?? 10)
        let expToken = exp.map { String(format: "%.1f", $0) }
        let glob = expToken.map { "Light_*_\($0)s_*.fit" } ?? "Light_*.fit"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))\(expToken.map { "-\($0)s" } ?? "")",
                                    isDirectory: true)
        let relay = FrameRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in
            Task { @MainActor in self?.log.append(msg) }
        }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        frameRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()
        if !isRunning {
            frameRelay?.stop(); frameRelay = nil
            return
        }
        selectedTab = .live
    }

    func startASIAIRLive() {
        guard !isRunning, !isImporting, !isDetecting else { return }
        zoomPan = .fit
        isDetecting = true
        log.append("Looking for ASIAIR share…")
        Task.detached { [weak self] in
            let found = ASIAIRDetector.detect()       // SMB directory work, off the main thread
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

    /// On-main configure + start for an auto-detected ASIAIR target folder.
    /// Unlike the Seestar path, the relay glob is `*.<ext>` (the ASIAIR target
    /// folder is already target-scoped) and `fileNamePrefix` is cleared: the
    /// relay dir is glob-filtered AND session-scoped, so the native stacker must
    /// accept every FITS in it — ASIAIR light files are not guaranteed to start
    /// with "Light_" (the .nativeStack default prefix would otherwise drop them).
    private func configureAndStartASIAIR(_ found: ASIAIRDetector.Found) {
        sourceMode = .nativeStack
        fileNamePrefix = ""                 // accept-all: see doc comment above
        neutralizeBackground = true
        targetName = found.target
        subExposureText = String(format: "%g", found.subExposure ?? 10)
        let glob = "*.\(found.subFileExtension)"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))",
                                    isDirectory: true)
        let relay = FrameRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in Task { @MainActor in self?.log.append(msg) } }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        frameRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()
        if !isRunning { frameRelay?.stop(); frameRelay = nil; return }
        selectedTab = .live
    }

    func endSession() {
        saveSettings()
        guard let p = pipeline else { return }
        guard !isGeneratingReplay else { return }
        isGeneratingReplay = true
        log.append("Ending session — generating replay…")

        // Stop the relay (if any) immediately — before the pipeline drains.
        frameRelay?.stop()
        frameRelay = nil

        // Scene automation stops immediately; the OBS stream/record stop is
        // deferred until AFTER the pipeline end/replay flow below.
        stopSceneAutomation()

        // If a broadcast is live, reset its state so the UI returns to idle.
        // The deliberate stopStream below acts as the safety net.
        if broadcastState == .live || broadcastState == .connecting {
            goLiveTask?.cancel()
            goLiveTask = nil
            healthPollTask?.cancel()
            healthPollTask = nil
            streamHealth = nil
            broadcastState = .idle
        }

        Task.detached { [weak self] in
            do {
                let url = try p.end()
                await MainActor.run {
                    self?.replayURL = url
                    self?.lastSessionDirectory = url.deletingLastPathComponent()
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Replay failed: \(error)" }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.isGeneratingReplay = false
                self?.pipeline = nil
                self?.sessionEnd = Date()
            }
        }

        // Deliberate end-of-session stop — the ONLY place we ask OBS to stop the
        // stream. App quit / abort paths never call this. Runs after the pipeline
        // end() is kicked off above; ordering vs. replay generation is immaterial.
        Task { [weak self] in
            guard let self else { return }
            await self.obs.stopStream()
            await self.obs.setRecording(false)
        }
    }

    // MARK: - OBS bring-up

    /// Connect to OBS, launching it if needed. Returns whether connected.
    /// Does NOT start any stream — broadcasting is deliberate (goLive()).
    private func connectOBS() async -> Bool {
        guard obs.state == .disconnected else { return true }  // already connected

        var connected = await obs.connect(host: obsHost, port: obsPort,
                                          password: obsPassword.isEmpty ? nil : obsPassword)

        if !connected && obsAutoLaunch {
            launchOBS()
            // Retry connect every 2 s until success or a 20 s budget elapses.
            let deadline = Date().addingTimeInterval(20)
            while !connected && Date() < deadline && !Task.isCancelled {
                // Cancellation-aware sleep: a cancel throws here, which we treat
                // as "stop retrying" — return false.
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return false }
                if obs.state == .disconnected {
                    connected = await obs.connect(host: obsHost, port: obsPort,
                                                 password: obsPassword.isEmpty ? nil : obsPassword)
                } else {
                    connected = obs.state != .disconnected
                }
            }
        }

        if !connected {
            log.append("OBS: not connected")
        }
        return connected
    }

    // MARK: - Broadcast orchestration

    func goLive() {
        guard broadcastState == .idle else { return }
        broadcastState = .connecting
        goLiveTask = Task { @MainActor in
            let connected = await connectOBS()
            guard connected else {
                errorMessage = "OBS not reachable — is it installed and running?"
                broadcastState = .idle; return
            }
            let scene = stackSceneName.isEmpty ? nil : stackSceneName
            let live = await obs.startBroadcast(scene: scene)
            // The user may have hit End Broadcast / End Session while we were
            // connecting. If so, don't transition to .live — instead undo the
            // broadcast we just started so nothing keeps running behind their back.
            guard broadcastState == .connecting else {
                if live { await obs.stopBroadcast() }
                return
            }
            if live {
                broadcastState = .live
                startHealthPoll()
            } else {
                errorMessage = "OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key)."
                broadcastState = .idle
            }
        }
    }

    func endBroadcast() {
        guard broadcastState == .live || broadcastState == .connecting else { return }
        broadcastState = .stopping
        goLiveTask?.cancel(); goLiveTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        Task { @MainActor in
            await obs.stopBroadcast()
            streamHealth = nil
            broadcastState = .idle
        }
    }

    private func startHealthPoll() {
        healthPollTask?.cancel()
        healthPollTask = Task { @MainActor in
            while !Task.isCancelled && broadcastState == .live {
                streamHealth = await obs.streamStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Launch OBS via NSWorkspace by bundle id; fall back to `open -a OBS`.
    /// NSWorkspace/AppKit is app-target-only (never in LiveAstroCore).
    private func launchOBS() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.obsBundleID) {
            log.append("OBS: launching \(url.lastPathComponent)…")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.log.append("OBS: launch failed: \(error.localizedDescription)") }
                }
            }
        } else {
            // Bundle id not resolvable — try the command-line fallback, and if
            // that isn't available either, just skip the launch and log.
            log.append("OBS: app not found by bundle id — trying `open -a OBS`")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "OBS"]
            do {
                try process.run()
            } catch {
                log.append("OBS: could not launch OBS (\(error.localizedDescription)) — skipping")
            }
        }
    }

    // MARK: - Scene automation

    /// Start the 15 s stall-check timer. Active only while a session runs AND
    /// scene automation is enabled. Seeds a StallDetector from the sub-exposure.
    private func startSceneAutomation() {
        stopSceneAutomation()   // idempotent
        guard sceneAutomationOn else { return }

        var detector = StallDetector(subExposureSeconds: profile.subExposureSeconds)
        // Seed the clock so we don't report a stall before the first frame.
        detector.recordUpdate(at: Date())
        stall = detector
        showingScopeDueToStall = false
        manualOverride = false
        lastAutomationScene = nil

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sceneTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneTimer = timer
    }

    private func stopSceneAutomation() {
        sceneTimer?.invalidate()
        sceneTimer = nil
        stall = nil
        showingScopeDueToStall = false
        manualOverride = false
        lastAutomationScene = nil
    }

    /// Fires every 15 s. If imaging has stalled and we aren't already showing the
    /// scope scene, switch to it once. Honors the manual-override flag.
    private func sceneTick() {
        guard sceneAutomationOn, isRunning, let detector = stall else { return }

        // Detect an operator-initiated program-scene change: if the current OBS
        // scene isn't the one automation last set (and isn't nil/unknown),
        // suspend automation until the next stall/resume boundary.
        detectManualOverride()

        let stalledNow = detector.isStalled(at: Date())
        if stalledNow && !showingScopeDueToStall && !manualOverride && !scopeSceneName.isEmpty {
            showingScopeDueToStall = true
            let scene = scopeSceneName
            Task { [weak self] in await self?.setSceneViaAutomation(scene) }
        }
    }

    /// Called on each accepted frame (main actor). Resets the stall clock and, if
    /// we were showing the scope scene due to a stall, switches back to the stack
    /// scene once. This is the "resume" boundary that also clears manual override.
    private func onFrameAccepted() {
        guard sceneAutomationOn, var detector = stall else { return }
        detector.recordUpdate(at: Date())
        stall = detector

        if showingScopeDueToStall {
            showingScopeDueToStall = false
            manualOverride = false   // resume boundary clears the override
            if !stackSceneName.isEmpty {
                let scene = stackSceneName
                Task { [weak self] in await self?.setSceneViaAutomation(scene) }
            }
        }
    }

    /// Set a scene *as automation*, remembering the name so a later
    /// CurrentProgramSceneChanged we caused isn't mistaken for a manual change.
    private func setSceneViaAutomation(_ name: String) async {
        lastAutomationScene = name
        await obs.setScene(name)
    }

    /// If OBS's current program scene differs from what automation last set (and
    /// is a real, known scene), the operator changed it by hand — suspend
    /// automation until the next stall/resume boundary.
    private func detectManualOverride() {
        guard let current = obs.currentScene else { return }
        if let expected = lastAutomationScene, current != expected, !manualOverride {
            manualOverride = true
            log.append("OBS: manual scene change detected (\(current)) — automation paused until next stall/resume")
        }
    }
}
