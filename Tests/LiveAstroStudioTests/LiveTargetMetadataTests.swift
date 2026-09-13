import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

/// The plain Start Session path never read the subs' headers, while import and the
/// Seestar/ASIAIR relays did. A stale typed target put "M 51" on the air over NGC 6960 subs.
@MainActor
final class LiveTargetMetadataTests: XCTestCase {

    private final class Source: FrameSource {
        let frames: AsyncStream<RawFrame>
        let continuation: AsyncStream<RawFrame>.Continuation
        let isFinite = false
        var totalCount: Int? { nil }
        init() {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }
            continuation = c
        }
        func start() throws {}
        func stop() { continuation.finish() }
    }

    /// Metadata must arrive through the real pipeline callback wiring even when no
    /// calibrator provider exists (the startup scan may already have found calibration).
    func testFirstLiveFrameUpdatesTheBoundModelWithoutACalibrationProvider() async throws {
        let model = makeModel()
        model.targetName = "M 51"
        model.subExposureText = "180"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: model.profile, rootDirectory: dir)
        model.attach(pipeline: pipeline)
        model.wireCallbacks(to: pipeline)
        model.isRunning = true
        try pipeline.start()
        let seen = expectation(description: "frame processed")
        let previous = pipeline.onSubFrame
        pipeline.onSubFrame = { record in previous?(record); seen.fulfill() }
        source.continuation.yield(RawFrame(image: AstroImage(width: 32, height: 32, channels: 1,
            pixels: [Float](repeating: 0.1, count: 1024), sourceIsLinear: true),
            bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "Light.fit",
            metadata: meta(object: "NGC 6960", exposure: 300)))
        await fulfillment(of: [seen], timeout: 10)
        for _ in 0..<100 where model.targetName != "NGC 6960" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.targetName, "NGC 6960")
        XCTAssertEqual(model.subExposureText, "300")
        source.stop()
        _ = try pipeline.end()
    }

    private func makeModel(_ name: String = #function) -> AppModel {
        let suite = "LiveTargetMetadataTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(userDefaults: defaults)
    }

    private func meta(object: String?, exposure: Double?) -> SourceMetadata {
        var m = SourceMetadata(); m.object = object; m.exposureSeconds = exposure; return m
    }

    func testQueuedMetadataCannotOverwriteAReboundPresentation() async throws {
        let model = makeModel()
        let source = Source()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: model.profile, rootDirectory: FileManager.default.temporaryDirectory)
        model.attach(pipeline: pipeline)
        model.isRunning = true
        model.wireCallbacks(to: pipeline)
        let oldDelivery = try XCTUnwrap(pipeline.onSourceMetadata)
        oldDelivery(meta(object: "Old target", exposure: 300))
        // Rebind the SAME pipeline: pointer equality alone cannot protect presentation ownership.
        model.wireCallbacks(to: pipeline)
        model.targetName = "New target"
        model.subExposureText = "20"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.targetName, "New target")
        XCTAssertEqual(model.subExposureText, "20")
        XCTAssertFalse(model.log.contains { $0.contains("Old target") })
    }

    func testQueuedMetadataCannotOverwriteSettingsAfterEndBegins() async throws {
        let model = makeModel()
        let pipeline = SessionPipeline(nativeSource: Source(), engine: StackEngine(),
            profile: model.profile, rootDirectory: FileManager.default.temporaryDirectory)
        model.attach(pipeline: pipeline)
        model.isRunning = true
        model.wireCallbacks(to: pipeline)
        let delivery = try XCTUnwrap(pipeline.onSourceMetadata)
        delivery(meta(object: "Old target", exposure: 300))
        model.importer.isGeneratingReplay = true
        model.targetName = "Next target"
        model.subExposureText = "20"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.targetName, "Next target")
        XCTAssertEqual(model.subExposureText, "20")
    }

    func testRestackCaptionUsesTheExposureOfItsWrittenMaster() {
        let model = makeModel()
        model.subExposureText = "180"
        var exposure = ExposureSummary()
        for _ in 0..<3 { exposure.add(FrameExposure(metadata: meta(object: nil, exposure: 300), fallback: 180)) }
        let report = RestackReport(exposure: exposure, master: AstroImage(width: 2, height: 2, channels: 1,
            pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: false), stackedCount: 3,
            skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        model.finishRestack(report, excludedCount: 0, writeResult: .init(ok: true, logMessage: nil),
            sessionDir: nil, neutralize: false, subExposureSeconds: 300)
        XCTAssertEqual(model.broadcastIntegrationCaption,
                       IntegrationFormat.caption(seconds: 900, frames: 3, subSeconds: 300))
        XCTAssertEqual(model.integrationCaption, model.broadcastIntegrationCaption)
    }

    // MARK: pure detection

    func testDetectedProfileTakesObjectAndExposureFromHeaders() {
        let d = AppModel.detectedProfile(from: meta(object: "NGC 6960", exposure: 300))
        XCTAssertEqual(d.targetName, "NGC 6960")
        XCTAssertEqual(d.subExposureText, "300")
    }

    func testDetectedProfileLeavesAbsentFieldsUntouched() {
        let d = AppModel.detectedProfile(from: meta(object: "", exposure: 0))
        XCTAssertNil(d.targetName, "an empty OBJECT must not blank a typed name")
        XCTAssertNil(d.subExposureText, "a zero exposure is not a value")
    }

    /// Same formatting as ImportController and LiveSourceController use, so all three
    /// paths agree on what lands in the exposure field.
    func testDetectedProfileFormatsExposureLikeTheOtherPaths() {
        XCTAssertEqual(AppModel.detectedProfile(from: meta(object: nil, exposure: 0.5)).subExposureText, "0.5")
        XCTAssertEqual(AppModel.detectedProfile(from: meta(object: nil, exposure: 180)).subExposureText, "180")
    }

    // MARK: adoption into the live profile

    /// The real case, and the policy decision: headers OVERWRITE a stale typed value, and the
    /// change is logged so a deliberately typed name is never lost silently.
    func testAdoptOverwritesStaleTypedValuesAndLogsTheChange() {
        let model = makeModel()
        model.targetName = "M 51"
        model.subExposureText = "180"

        let changed = model.adoptSourceMetadata(meta(object: "NGC 6960", exposure: 300))

        XCTAssertTrue(changed)
        XCTAssertEqual(model.targetName, "NGC 6960")
        XCTAssertEqual(model.subExposureText, "300")
        XCTAssertTrue(model.log.contains { $0.contains("NGC 6960") && $0.contains("was M 51") },
                      "the overwrite must be visible: \(model.log)")
        XCTAssertTrue(model.log.contains { $0.contains("300") && $0.contains("was 180") }, "\(model.log)")
    }

    func testAdoptIsSilentWhenHeadersAgreeWithTheProfile() {
        let model = makeModel()
        model.targetName = "NGC 6960"
        model.subExposureText = "300"
        let before = model.log.count

        let changed = model.adoptSourceMetadata(meta(object: "NGC 6960", exposure: 300))

        XCTAssertFalse(changed)
        XCTAssertEqual(model.log.count, before, "nothing changed, so nothing to say: \(model.log)")
    }

    func testAdoptKeepsTypedValuesWhenHeadersCarryNone() {
        let model = makeModel()
        model.targetName = "Veil"
        model.subExposureText = "120"

        let changed = model.adoptSourceMetadata(meta(object: nil, exposure: nil))

        XCTAssertFalse(changed)
        XCTAssertEqual(model.targetName, "Veil")
        XCTAssertEqual(model.subExposureText, "120")
    }
}
