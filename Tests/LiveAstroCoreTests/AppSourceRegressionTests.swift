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
}
