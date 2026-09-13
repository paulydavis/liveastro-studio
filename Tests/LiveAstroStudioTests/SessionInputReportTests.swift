import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

/// Red-first for the app half of "silent about its input".
///
/// A session must say what it is about to consume BEFORE it consumes it: pre-existing subs
/// get an explicit choice, and a filter matching nothing gets a standing status instead of a
/// silence indistinguishable from "capture hasn't started".
@MainActor
final class SessionInputReportTests: XCTestCase {

    func testStartQuestionCarriesVerifiedContentBaseline() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFITS(dir, name: "Light_old.fit")
        let expectedDigest = FileIdentity.contentDigest(data: try Data(contentsOf: file))
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isPreparingSessionInput)
        XCTAssertEqual(model.pendingSessionStart?.snapshot.existing["Light_old.fit"]?.digest, expectedDigest)
        model.resolvePendingSessionStart(.cancel)
    }

    func testCancelInputPreparationCompletesOnceAndCannotReopenQuestion() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_old.fit")
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        var results: [Bool] = []
        model.startSession { results.append($0) }
        XCTAssertTrue(model.isPreparingSessionInput, "filesystem work must not block Start's main-actor caller")
        model.cancelSessionInputPreparation()
        model.cancelSessionInputPreparation()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(results, [false])
        XCTAssertNil(model.pendingSessionStart)
        XCTAssertNil(model.sessionInputStatus)
        XCTAssertFalse(model.isRunning)
    }

    func testInputPreparationRechecksSelectionBeforeOfferingQuestion() async throws {
        let (model, _) = makeModel()
        let first = try makeTempDir(), second = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try writeFITS(first, name: "Light_old.fit")
        try writeFITS(second, name: "Light_other.fit")
        model.sourceMode = .nativeStack; model.watchFolder = first; model.fileNamePrefix = "Light_"
        model.startSession()
        model.watchFolder = second
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.pendingSessionStart?.snapshot.folder, second)
        XCTAssertFalse(model.isRunning)
        model.resolvePendingSessionStart(.cancel)
    }

    func testRejectedFrameClearsWaitingButOldSessionCannot() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = SessionPipeline(watchFolder: dir, profile: model.profile, rootDirectory: dir)
        let current = SessionPipeline(watchFolder: dir, profile: model.profile, rootDirectory: dir)
        model.wireCallbacks(to: old)
        model.wireCallbacks(to: current)
        let waiting = AppModel.SessionInputStatus.waitingForFirstSub(folder: dir, filter: nil, unmatchedFileCount: 0)
        model.installSessionInputStatusForTest(waiting)
        old.onRejected?(.insufficientStars(found: 0), "old.fit")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.sessionInputStatus, waiting)
        XCTAssertEqual(model.rejectedCount, 0)
        current.onRejected?(.insufficientStars(found: 0), "current.fit")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.sessionInputStatus)
        XCTAssertEqual(model.rejectedCount, 1)
    }

    func testLateDetectionCannotRedirectManualStartQuestion() async throws {
        let (model, _) = makeModel()
        let manual = try makeTempDir(), detected = try makeTempDir(), relayRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: manual); try? FileManager.default.removeItem(at: detected); try? FileManager.default.removeItem(at: relayRoot) }
        var surface = AppSurface(log: { _ in }, presentError: { _ in }, isSessionRunning: { model.isRunning },
            applyDetectedProfile: { if let folder = $0.watchFolder { model.watchFolder = folder } },
            currentTargetName: { "InputTest" }, startSession: { model.startSession(completion: $0) })
        surface.isSessionStartPending = { model.hasPendingSessionStart }
        model.liveSource = LiveSourceController(surface: surface, relayRoot: relayRoot)
        try writeFITS(manual, name: "Light_manual.fit")
        model.watchFolder = manual; model.sourceMode = .nativeStack; model.fileNamePrefix = "Light_"
        // Main actor cannot service detection's completion until after manual Start below.
        model.liveSource.startWatchFolderLive(source: detected)
        model.startSession()
        XCTAssertTrue(model.hasPendingSessionStart)
        for _ in 0..<300 where model.liveSource.isDetecting || model.isPreparingSessionInput {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.liveSource.isDetecting)
        XCTAssertEqual(model.watchFolder, manual)
        XCTAssertEqual(model.pendingSessionStart?.snapshot.folder, manual)
        XCTAssertFalse(model.liveSource.isStarting)
        model.resolvePendingSessionStart(.cancel)
        model.liveSource.stopRelay()
    }

    private func waitForPreparation(_ model: AppModel) async throws {
        for _ in 0..<500 where model.isPreparingSessionInput {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isPreparingSessionInput, "input preparation timed out")
    }

    /// Per-test defaults: a bare AppModel() would read and write the real user's domain.
    private func makeModel(_ name: String = #function) -> (AppModel, UserDefaults) {
        let suite = "SessionInputReportTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AppModel(userDefaults: defaults), defaults)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFITS(_ dir: URL, name: String) throws -> URL {
        let px = [Float](repeating: 0.2, count: 64 * 32)
        let url = dir.appendingPathComponent(name)
        try FITSWriter.float32(width: 64, height: 32, channels: 1, pixels: px).write(to: url)
        return url
    }

    // MARK: - Pre-existing subs are a question, not a silent decision

    func testStartOnAFolderHoldingSubsAsksBeforeStackingAnything() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        try writeFITS(dir, name: "Light_002.fit")

        model.sourceMode = .nativeStack
        model.watchFolder = dir
        model.fileNamePrefix = "Light_"
        model.startSession()
        try await waitForPreparation(model)

        XCTAssertFalse(model.isRunning, "nothing may be stacked until the operator answers")
        XCTAssertEqual(model.pendingSessionStart?.snapshot.count, 2)
        XCTAssertEqual(model.pendingSessionStart?.snapshot.unmatchedFileCount, 0)
    }

    func testCancellingThePendingStartStartsNothing() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")

        model.sourceMode = .nativeStack
        model.watchFolder = dir
        model.fileNamePrefix = "Light_"
        model.startSession()
        try await waitForPreparation(model)
        XCTAssertNotNil(model.pendingSessionStart)

        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.pendingSessionStart)
    }

    /// The choice decides exclusion, and only "New arrivals only" excludes anything.
    func testChoiceDeterminesExclusion() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")

        XCTAssertNil(AppModel.exclusion(for: .stackExistingAndNew, snapshot: snapshot,
                                        folder: dir, fileNamePrefix: "Light_"),
                     "'Stack existing + new' must behave exactly as before")
        XCTAssertEqual(AppModel.exclusion(for: .newArrivalsOnly, snapshot: snapshot,
                                          folder: dir, fileNamePrefix: "Light_"), snapshot)
    }

    /// The snapshot is answered later. If the operator changed folder or filter while the
    /// question was open, it describes something else and must not exclude anything.
    func testStaleSnapshotIsNotUsedForExclusion() async throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        try writeFITS(dir, name: "Light_001.fit")
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")

        XCTAssertNil(AppModel.exclusion(for: .newArrivalsOnly, snapshot: snapshot,
                                        folder: other, fileNamePrefix: "Light_"),
                     "folder changed under the question — excluding by it could drop real captures")
        XCTAssertNil(AppModel.exclusion(for: .newArrivalsOnly, snapshot: snapshot,
                                        folder: dir, fileNamePrefix: "Sub_"),
                     "filter changed under the question")
    }

    // MARK: - Zero matches is a standing status, and a failure is not zero matches

    func testLiveStartRefusesWhileRestackOwnsPresentation() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        XCTAssertTrue(model.claimRestackPresentation())
        var result: Bool?
        model.startSession { result = $0 }
        try await waitForPreparation(model)
        XCTAssertEqual(result, false)
        XCTAssertNil(model.pendingSessionStart, "must not offer Start while restack owns presentation")
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.isRestacking)
    }

    func testPendingStartRechecksRestackOwnershipBeforeStarting() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        var result: Bool?
        model.startSession { result = $0 }
        try await waitForPreparation(model)
        XCTAssertNotNil(model.pendingSessionStart)
        XCTAssertTrue(model.claimRestackPresentation())
        model.resolvePendingSessionStart(.stackExistingAndNew)
        try await waitForPreparation(model)
        XCTAssertEqual(result, false)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.isRestacking)
    }

    func testPendingStartCompletesOnlyAfterCancel() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        var results: [Bool] = []
        model.startSession { results.append($0) }
        try await waitForPreparation(model)
        XCTAssertNotNil(model.pendingSessionStart)
        XCTAssertTrue(results.isEmpty, "pending is not failure")
        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
        XCTAssertEqual(results, [false])
        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
        XCTAssertEqual(results, [false], "completion is exactly once")
    }

    func testExcludedSubsDoNotSelectCalibration() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertTrue(model.resolveCalibration(watchFolder: dir, prefix: "Light_").foundMetadata,
                      "fixture must provide readable metadata")
        let result = model.resolveCalibration(watchFolder: dir, prefix: "Light_", excludingPreExisting: snapshot)
        XCTAssertFalse(result.foundMetadata, "new-arrivals session must resolve from its first eligible frame")
        XCTAssertNil(result.calibrator)
    }

    func testRelayContinuesCopyingWhileStartAwaitsAnswer() async throws {
        try await exerciseRelay(reprompt: false)
    }

    func testRelaySurvivesFilterReconfirmation() async throws {
        try await exerciseRelay(reprompt: true)
    }

    private func exerciseRelay(reprompt: Bool) async throws {
        let (model, _) = makeModel()
        let source = try makeTempDir(), root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = root.appendingPathComponent("InputTest-\(df.string(from: Date()))")
        try FileManager.default.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try writeFITS(relayDir, name: "Light_old.fit")
        model.sourceMode = .nativeStack; model.fileNamePrefix = "Light_"
        let controller = LiveSourceController(surface: AppSurface(
            log: { _ in }, presentError: { XCTFail($0) }, isSessionRunning: { model.isRunning },
            applyDetectedProfile: { if let folder = $0.watchFolder { model.watchFolder = folder } },
            currentTargetName: { "InputTest" }, startSession: { model.startSession(completion: $0) }), relayRoot: root)
        controller.relayRetentionDays = 0
        defer { controller.stopRelay() }
        controller.startWatchFolderLive(source: source)
        for _ in 0..<200 where model.pendingSessionStart == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.pendingSessionStart, "prerequisite: confirmation is open")
        if reprompt {
            model.fileNamePrefix = ""
            model.resolvePendingSessionStart(.newArrivalsOnly)
            try await waitForPreparation(model)
            XCTAssertNotNil(model.pendingSessionStart, "changed filter needs a new question")
            XCTAssertTrue(controller.isStarting, "same-folder re-prompt still owns its live relay")
        }
        try writeFITS(source, name: "Light_new.fit")
        let copied = relayDir.appendingPathComponent("Light_new.fit")
        // Production relay requires two stable observations, on five-second polls.
        for _ in 0..<2000 where !FileManager.default.fileExists(atPath: copied.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "confirmation must not stop capture forwarding")
        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
        XCTAssertFalse(controller.isStarting)
    }

    func testOldDialogDismissalCannotCancelReplacement() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        model.sourceMode = .nativeStack; model.watchFolder = dir; model.fileNamePrefix = "Light_"
        model.startSession()
        try await waitForPreparation(model)
        let old = try XCTUnwrap(model.pendingSessionStart?.id)
        model.fileNamePrefix = ""
        model.resolvePendingSessionStart(.newArrivalsOnly, requestID: old)
        try await waitForPreparation(model)
        let replacement = try XCTUnwrap(model.pendingSessionStart?.id)
        XCTAssertNotEqual(old, replacement)
        model.resolvePendingSessionStart(.cancel, requestID: old)
        try await waitForPreparation(model)
        XCTAssertEqual(model.pendingSessionStart?.id, replacement)
        model.resolvePendingSessionStart(.cancel, requestID: replacement)
        try await waitForPreparation(model)
        XCTAssertNil(model.pendingSessionStart)
    }

    func testRetryOnPopulatedFolderRetiresPreviousFailure() async throws {
        let (model, _) = makeModel()
        model.sourceMode = .nativeStack
        model.watchFolder = URL(fileURLWithPath: "/missing/\(UUID().uuidString)")
        model.startSession()
        try await waitForPreparation(model)
        guard case .failed = model.sessionInputStatus else { return XCTFail("missing prerequisite failure") }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit")
        model.watchFolder = dir
        model.fileNamePrefix = "Light_"
        model.startSession()
        try await waitForPreparation(model)
        XCTAssertNotNil(model.pendingSessionStart)
        XCTAssertNil(model.sessionInputStatus)
        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
    }

    func testStackAllRechecksChangedFolderBeforeStarting() async throws {
        let (model, _) = makeModel()
        let first = try makeTempDir(), second = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try writeFITS(first, name: "Light_001.fit")
        try writeFITS(second, name: "Light_002.fit")
        model.sourceMode = .nativeStack; model.fileNamePrefix = "Light_"; model.watchFolder = first
        model.startSession()
        try await waitForPreparation(model)
        XCTAssertNotNil(model.pendingSessionStart)
        model.watchFolder = second
        // Prevent the broken implementation from starting real disk/notification work.
        model.importer.isImporting = true
        model.resolvePendingSessionStart(.stackExistingAndNew)
        try await waitForPreparation(model)
        XCTAssertEqual(model.pendingSessionStart?.snapshot.folder, second)
        XCTAssertFalse(model.isRunning)
        model.resolvePendingSessionStart(.cancel)
        try await waitForPreparation(model)
    }

    func testAcceptedCallbackClearsWaitingButDiscoveryDoesNot() async throws {
        let (model, _) = makeModel()
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pipeline = SessionPipeline(watchFolder: dir,
            profile: SessionProfile(targetName: "input-test", subExposureSeconds: 1), rootDirectory: dir)
        model.wireCallbacks(to: pipeline)
        model.installSessionInputStatusForTest(.waitingForFirstSub(folder: dir, filter: nil, unmatchedFileCount: 0))
        pipeline.onLog?("discovered candidate")
        await Task.yield()
        XCTAssertNotNil(model.sessionInputStatus)
        let record = SnapshotRecord(index: 1, timestamp: Date(), sourceFile: "Light.fit",
            snapshotFile: "snapshot.png", estimatedIntegrationSeconds: 1,
            width: 1, height: 1, mean: 0, median: 0, stddev: 0)
        let image = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 1, height: 1, channels: 1,
            pixels: [0.2], sourceIsLinear: false)))
        pipeline.onUpdate?(image, record)
        for _ in 0..<100 where model.latestRecord == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.latestRecord?.index, 1, "accepted handler actually ran")
        XCTAssertNil(model.sessionInputStatus)
    }

    func testZeroMatchesReportsFolderAndFilterAndKeepsWaiting() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Sub_001.fit")   // present, but the filter rejects it

        // The decision is asserted directly: actually starting needs an app bundle and a live
        // pipeline, neither of which exists in a unit test.
        guard case .startWaiting(.waitingForFirstSub(let folder, let filter, let unmatched)) =
                AppModel.startDecision(folder: dir, fileNamePrefix: "Light_") else {
            return XCTFail("expected a standing waiting status")
        }
        XCTAssertEqual(folder, dir)
        XCTAssertEqual(filter, "Light_")
        XCTAssertEqual(unmatched, 1, "'1 file present, none match' is the prefix-typo tell")
    }

    /// An unreadable folder must never render as "no matching subs found, waiting" — that
    /// tells the operator to wait for files that can never arrive.
    func testUnreadableFolderReportsAFailureNotAnEmptyFolder() async throws {
        let (model, _) = makeModel()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        model.sourceMode = .nativeStack
        model.watchFolder = missing
        model.fileNamePrefix = "Light_"
        model.startSession()
        try await waitForPreparation(model)

        XCTAssertFalse(model.isRunning)
        if case .waitingForFirstSub = model.sessionInputStatus {
            XCTFail("a read failure was reported as an empty folder")
        }
        guard case .failed = model.sessionInputStatus else {
            return XCTFail("expected a failure status, got \(String(describing: model.sessionInputStatus))")
        }
        XCTAssertNotNil(model.errorMessage)
    }

    func testEndingRetiresWaitingStatus() {
        let (model, _) = makeModel()
        model.installSessionInputStatusForTest(.waitingForFirstSub(
            folder: URL(fileURLWithPath: "/unused"), filter: nil, unmatchedFileCount: 0))
        model.endSession()
        XCTAssertNil(model.sessionInputStatus)
    }

    /// A failure status is not a wait, and must not be cleared by an ingested frame either.
    func testIngestDoesNotClearAFailureStatus() {
        let (model, _) = makeModel()
        model.installSessionInputStatusForTest(.failed("cannot read folder"))
        model.noteFrameIngested()
        XCTAssertEqual(model.sessionInputStatus, .failed("cannot read folder"))
    }
}
