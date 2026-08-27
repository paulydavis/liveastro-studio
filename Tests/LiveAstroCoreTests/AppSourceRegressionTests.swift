import XCTest

final class AppSourceRegressionTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testStackerOutputWorkflowPassesRequestedModeThroughLiveSourceController() throws {
        let controllerURL = root.appendingPathComponent("Sources/LiveAstroStudio/LiveSourceController.swift")
        // The Start Workflow rows moved from ControlView to CaptureSettingsView, and the shared
        // watch-folder picker to AppModel, in the Setup TabView split. The behavioral guard is
        // unchanged: the row must pass its OWN sourceMode explicitly, never rely on ambient state.
        let captureViewURL = root.appendingPathComponent("Sources/LiveAstroStudio/CaptureSettingsView.swift")
        let appModelURL = root.appendingPathComponent("Sources/LiveAstroStudio/AppModel.swift")
        let controller = try String(contentsOf: controllerURL, encoding: .utf8)
        let captureView = try String(contentsOf: captureViewURL, encoding: .utf8)
        let appModel = try String(contentsOf: appModelURL, encoding: .utf8)

        XCTAssertTrue(
            appModel.contains("startWatchFolderLive(source: url, sourceMode: sourceMode)"),
            "pickWatchFolderLive must forward the REQUESTED sourceMode into LiveSourceController, not read back mutable AppModel state."
        )
        XCTAssertTrue(
            captureView.contains("sourceMode: .stackerOutput"),
            "The Watch Siril / External Stacker row must pass .stackerOutput explicitly instead of relying on mutable AppModel.sourceMode."
        )
        XCTAssertTrue(
            controller.contains("func startWatchFolderLive(source: URL, sourceMode: AppModel.SourceMode = .nativeStack)"),
            "LiveSourceController should accept the requested source mode, defaulting only the legacy/native callers."
        )
        XCTAssertTrue(
            controller.contains("configureAndStartWatchFolder(source: source, sourceMode: sourceMode, meta: meta)"),
            "The async detect completion must carry the originally selected mode through to configuration."
        )
        XCTAssertTrue(
            controller.contains("DetectedProfile(sourceMode: sourceMode, neutralizeBackground: true)"),
            "The detected profile must honor the selected mode; hard-coding .nativeStack breaks the Siril/external-stacker row."
        )
        XCTAssertFalse(
            controller.contains("DetectedProfile(sourceMode: .nativeStack, neutralizeBackground: true)"),
            "The watch-folder configure path must not overwrite the stacker-output row with nativeStack."
        )
    }

    func testAppModelPushesDisplayAdjustmentsToPipelineIndependentOfRenderThrottle() throws {
        let appModelURL = root.appendingPathComponent("Sources/LiveAstroStudio/AppModel.swift")
        let appModel = try String(contentsOf: appModelURL, encoding: .utf8)

        XCTAssertTrue(
            appModel.contains("p.displayAdjustments = displayAdjustments"),
            "A new SessionPipeline must receive persisted display adjustments before it starts rendering frames."
        )
        XCTAssertTrue(
            appModel.contains("pipeline.displayAdjustments = adj"),
            "applyDisplayAdjustments must always push state into the pipeline; the throttle may skip only the expensive re-render."
        )
        XCTAssertFalse(
            appModel.contains("guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else { return }"),
            "The 80 ms throttle must not return before updating SessionPipeline.displayAdjustments."
        )
    }

    func testURLSessionOBSSocketOpenDelegateAndStateAreReusableAcrossReconnects() throws {
        let socketURL = root.appendingPathComponent("Sources/LiveAstroCore/OBS/OBSSocket.swift")
        let source = try String(contentsOf: socketURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("private let stateLock = NSLock()"),
            "URLSessionOBSSocket must guard task/session access; URLSession delegate callbacks and close/send/receive can arrive on different threads."
        )
        XCTAssertTrue(
            source.contains("settled = false"),
            "OpenDelegate.awaitOpen must reset settled for each connect; otherwise the second connect can park forever."
        )
        XCTAssertTrue(
            source.contains("private var expectedTask: URLSessionTask?"),
            "OpenDelegate must remember which task owns the pending continuation so stale callbacks from an older URLSession cannot settle a fresh connect."
        )
        XCTAssertTrue(
            source.contains("openDelegate.awaitOpen(cont, task: t)"),
            "connect() must pass the newly-created task identity into awaitOpen before resume()."
        )
        XCTAssertTrue(
            source.contains("resume(.success(()), for: webSocketTask)"),
            "didOpen callbacks must settle only through the task-checked resume path."
        )
        XCTAssertTrue(
            source.contains("guard task === expectedTask, !settled, let cont = continuation"),
            "The delegate must check task identity and settle the continuation under one lock."
        )
        XCTAssertTrue(
            source.contains("takeStateForClose()"),
            "close() must atomically detach task/session before cancelling them, so reconnect cannot race stale teardown."
        )
    }

    func testOBSMessageValidatesJSONBeforeEncoding() throws {
        let messageURL = root.appendingPathComponent("Sources/LiveAstroCore/OBS/OBSMessage.swift")
        let source = try String(contentsOf: messageURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("JSONSerialization.isValidJSONObject(envelope)"),
            "OBSMessage must reject Date/NaN-style requestData before JSONSerialization can raise an Objective-C exception."
        )
    }

    func testImportControllerReleasesPipelineAndScansMetadataOffMainActor() throws {
        let controllerURL = root.appendingPathComponent("Sources/LiveAstroStudio/ImportController.swift")
        let pipelineURL = root.appendingPathComponent("Sources/LiveAstroCore/Pipeline/SessionPipeline.swift")
        let appSurfaceURL = root.appendingPathComponent("Sources/LiveAstroStudio/AppSurface.swift")
        let appModelURL = root.appendingPathComponent("Sources/LiveAstroStudio/AppModel.swift")
        let source = try String(contentsOf: controllerURL, encoding: .utf8)
        let pipeline = try String(contentsOf: pipelineURL, encoding: .utf8)
        let appSurface = try String(contentsOf: appSurfaceURL, encoding: .utf8)
        let appModel = try String(contentsOf: appModelURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("Task.detached { [weak self, folder, prefix] in"),
            "importSubs must move the initial newest-FITS metadata scan off MainActor; SMB enumeration/header reads can be slow."
        )
        XCTAssertTrue(
            source.contains("let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: folder)"),
            "The off-main import preparation task must perform the metadata read before returning to MainActor."
        )
        XCTAssertTrue(
            source.contains("self.importPipeline = nil"),
            "ImportController must release its full-resolution SessionPipeline after success/failure/cancel so the accumulator is not retained forever."
        )
        XCTAssertTrue(
            appSurface.contains("currentDisplayAdjustments: (() -> DisplayAdjustments)?"),
            "ImportController needs display-adjustment access through AppSurface so Stack Previous Shoot snapshots/replays honor persisted stretch/saturation/DBE."
        )
        XCTAssertTrue(
            appModel.contains("currentDisplayAdjustments: { [weak self] in MainActor.assumeIsolated { self?.displayAdjustments ?? .neutral } }"),
            "AppModel must wire persisted display adjustments into the import surface."
        )
        XCTAssertTrue(
            source.contains("importPipeline.displayAdjustments = surface.currentDisplayAdjustments?() ?? .neutral"),
            "The one-shot import pipeline must be seeded with current display adjustments before callbacks/rendering."
        )
        XCTAssertTrue(
            source.contains("private var importPrepareGeneration = 0"),
            "Import prepare needs a generation token so cancel invalidates detached metadata scans before beginImport."
        )
        XCTAssertTrue(
            source.contains("private var importPrepareInFlight = false"),
            "ImportController must distinguish prepare-with-no-pipeline from cancel-drain-with-no-pipeline; double cancel must not unlock UI mid-finalization."
        )
        XCTAssertTrue(
            source.contains("beginImport(from: folder, meta: meta, prefix: prefix, generation: generation)"),
            "The detached prepare completion must carry the generation it started under."
        )
        XCTAssertTrue(
            source.contains("guard generation == importPrepareGeneration"),
            "beginImport must reject stale/cancelled prepare completions before starting a pipeline."
        )
        XCTAssertTrue(
            source.contains("if importPipeline == nil {"),
            "cancelImport must handle the prepare phase, where isImporting is true but no pipeline exists yet."
        )
        XCTAssertTrue(
            source.contains("if let pipelineError = error as? SessionPipelineError, pipelineError == .shutdownTimeout"),
            "ImportController must not map a shutdownTimeout for a folder full of valid but stalled subs to the zero-match No .fit message."
        )
        XCTAssertTrue(
            pipeline.contains("Import stalled with no progress — cancelling remaining frames and finalizing completed frames."),
            "A progress-free internal import cancel must leave an honest log when it finalizes a partial import."
        )
    }

    func testLiveSourceDetectCompletionsRecheckSessionStateBeforeConfiguring() throws {
        let controllerURL = root.appendingPathComponent("Sources/LiveAstroStudio/LiveSourceController.swift")
        let source = try String(contentsOf: controllerURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("private func canApplyDetectedLiveSource() -> Bool"),
            "Live auto-detect completions need one shared post-await guard before mutating profile, starting relay, or starting a session."
        )
        XCTAssertEqual(
            source.components(separatedBy: "guard self.canApplyDetectedLiveSource() else").count - 1,
            3,
            "Watch-folder, Seestar, and ASIAIR detect completions must all re-check that no session/import started while detection was in flight."
        )
        XCTAssertTrue(
            source.contains("if !canApplyDetectedLiveSource() { return }"),
            "Configure helpers must also guard direct/internal calls before creating a relay."
        )
    }

    /// Pins the P2#1 fix (session-completion post-merge review): the planned-stop
    /// deadline must anchor on the shared armed-at anchor, NOT sessionStart — and
    /// BOTH the driver tick and the Live-tab countdown must use the SAME anchor, or
    /// they diverge and the stop can fire immediately on a mid-session enable.
    func testPlannedStopUsesSharedArmedAtAnchorInDriverAndDisplay() throws {
        let appModel = try String(contentsOf: root.appendingPathComponent("Sources/LiveAstroStudio/AppModel.swift"), encoding: .utf8)
        let broadcast = try String(contentsOf: root.appendingPathComponent("Sources/LiveAstroStudio/BroadcastView.swift"), encoding: .utf8)

        XCTAssertTrue(appModel.contains("var plannedStopArmedAt"),
            "AppModel must track when planned-stop was armed, so a mid-session enable anchors on the enable time, not sessionStart.")
        XCTAssertTrue(appModel.contains("var plannedStopAnchor"),
            "AppModel must expose one shared plannedStopAnchor so the driver and the display agree.")
        XCTAssertTrue(appModel.contains("plannedStopAnchor: self.plannedStopAnchor")
                      || appModel.contains("plannedStopAnchor: plannedStopAnchor"),
            "The driver tick must feed the shared plannedStopAnchor into step(), not sessionStart.")
        XCTAssertFalse(appModel.contains("plannedStopAnchor: self.sessionStart")
                       || appModel.contains("plannedStopAnchor: sessionStart"),
            "Regression: the tick must NOT anchor the planned stop on sessionStart (fires immediately on a mid-session enable).")
        XCTAssertTrue(broadcast.contains("model.plannedStopAnchor"),
            "The Live-tab countdown must use the SAME shared anchor as the driver, or display and firing disagree.")
    }

}
