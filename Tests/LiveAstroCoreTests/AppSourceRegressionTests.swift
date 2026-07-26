import XCTest

final class AppSourceRegressionTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testStackerOutputWorkflowPassesRequestedModeThroughLiveSourceController() throws {
        let controllerURL = root.appendingPathComponent("Sources/LiveAstroStudio/LiveSourceController.swift")
        let controlViewURL = root.appendingPathComponent("Sources/LiveAstroStudio/ControlView.swift")
        let controller = try String(contentsOf: controllerURL, encoding: .utf8)
        let controlView = try String(contentsOf: controlViewURL, encoding: .utf8)

        XCTAssertTrue(
            controlView.contains("model.liveSource.startWatchFolderLive(source: url, sourceMode: sourceMode)"),
            "ControlView must pass the row's selected sourceMode into LiveSourceController instead of relying on mutable AppModel state."
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
            source.contains("takeStateForClose()"),
            "close() must atomically detach task/session before cancelling them, so reconnect cannot race stale teardown."
        )
    }

    func testImportControllerReleasesPipelineAndScansMetadataOffMainActor() throws {
        let controllerURL = root.appendingPathComponent("Sources/LiveAstroStudio/ImportController.swift")
        let source = try String(contentsOf: controllerURL, encoding: .utf8)

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
}
