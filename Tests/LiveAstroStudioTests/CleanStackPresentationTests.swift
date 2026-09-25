import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class CleanStackPresentationTests: XCTestCase {
    private struct Loader: FrameLoader {
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            AstroImage(width: 12, height: 12, channels: 1, pixels: [Float](repeating: 0.4, count: 144), sourceIsLinear: true)
        }
    }
    private final class GatedLoader: FrameLoader, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        let release = DispatchSemaphore(value: 0)
        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            lock.lock(); let first = !entered; entered = true; lock.unlock()
            if first && release.wait(timeout: .now() + 5) != .success { throw CocoaError(.fileReadUnknown) }
            return try Loader().loadRegisteredInput(url: url, expectedContentDigest: expectedContentDigest)
        }
    }
    private func fixture(loader: FrameLoader? = nil) throws -> (AppModel, CleanStackCompletion, URL) {
        let suite = "CleanStackPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager(rootDirectory: root)
        let dir = try manager.startSession(profile: SessionProfile(targetName: "Retry", subExposureSeconds: 30), masterExpected: true)
        let status = CleanStackStatus(expectedCount: 6, savedCount: 5,
            expectedExposure: .estimated(count: 6, seconds: 30), savedExposure: .estimated(count: 5, seconds: 30),
            savedClean: true, reason: .timedOut)
        try manager.endSession(finalization: .init(masterOutcome: .written, stackFrameCount: 6,
            sessionAcceptedCount: 6, sessionRejectedCount: 0, exposure: status.savedExposure, cleanStackStatus: status))
        try Data("old master".utf8).write(to: dir.appendingPathComponent("master.fit"))
        let regs = (0..<6).map { SubRegistration(subIndex: $0, contentDigest: nil,
            relayURL: dir.appendingPathComponent("\($0).fit"), stackGeneration: 0, referenceIdentity: nil,
            transform: .identity, effectiveScale: 1, weight: 1, leveling: nil,
            exposure: FrameExposure(metadata: nil, fallback: 30)) }
        let request = try CleanStackCompletion(directory: dir, survivors: regs, generation: 0,
            kappa: 3, budget: 1_000_000, minSubs: 5, loader: loader ?? Loader(), metadata: nil,
            neutralize: false, fallbackSeconds: 30, status: status)
        return (AppModel(userDefaults: defaults, relayRoot: root.appendingPathComponent("relay")), request, dir)
    }

    func testFinishUsesRealWorkerAndBlocksOtherRestackUntilCompletion() async throws {
        let (model, request, dir) = try fixture()
        model.presentCleanStackCompletion(request, status: request.status)
        XCTAssertTrue(model.canFinishCleanStack)
        model.finishCleanStack()
        XCTAssertTrue(model.isRestacking, "ownership must be claimed before scheduling detached work")
        XCTAssertFalse(model.claimRestackPresentation())
        for _ in 0..<500 where model.isRestacking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRestacking, "completion must reach the real main-actor handler")
        XCTAssertEqual(model.cleanStackStatus?.savedCount, 6)
        XCTAssertFalse(model.canFinishCleanStack)
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(header.keywords["STACKCNT"].flatMap(Int.init), 6)
    }

    func testImportTransitionRetiresPreviousSessionsCompletion() throws {
        let (model, request, _) = try fixture()
        model.presentCleanStackCompletion(request, status: request.status)
        XCTAssertTrue(model.canFinishCleanStack)
        model.resetSessionStatsForImport()
        XCTAssertNil(model.cleanStackStatus)
        XCTAssertFalse(model.canFinishCleanStack)
    }

    func testCancelFromMainActorReachesWorkerAndPreservesRetry() async throws {
        let loader = GatedLoader()
        let (model, request, dir) = try fixture(loader: loader)
        let before = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        model.presentCleanStackCompletion(request, status: request.status)
        model.finishCleanStack()
        for _ in 0..<300 where !loader.hasEntered { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(loader.hasEntered, "prerequisite: worker is parked inside its first file load")
        model.cancelCleanStack()
        loader.release.signal()
        for _ in 0..<500 where model.isRestacking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRestacking)
        XCTAssertTrue(model.canFinishCleanStack, "cancel must retain the request for retry")
        XCTAssertNil(model.errorMessage, "cancellation is not a read failure or another worker error")
        XCTAssertEqual(model.cleanStackStatus?.savedCount, 5)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), before)
    }

    func testNewRelayDetectionCannotStartDuringCompletion() async throws {
        try await checkRelayOwnership(alreadyDetecting: false)
    }

    func testAppModelsOwnRelayHonorsCompletionOwnership() async throws {
        let (model, _, dir) = try fixture()
        let source = dir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { model.liveSource.stopRelay() }
        XCTAssertTrue(model.claimRestackPresentation())
        model.liveSource.startWatchFolderLive(source: source)
        XCTAssertFalse(model.liveSource.isDetecting, "AppModel must wire its real busy state into the relay controller")
        // Drain an incorrectly started detector too, keeping its side effects in
        // this test's scratch relay root rather than the operator's relay folder.
        for _ in 0..<500 where model.liveSource.isDetecting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.liveSource.isDetecting)
        XCTAssertFalse(model.isRunning)
    }

    func testLateRelayDetectionCannotApplyDuringCompletion() async throws {
        try await checkRelayOwnership(alreadyDetecting: true)
    }

    private func checkRelayOwnership(alreadyDetecting: Bool) async throws {
        let (model, _, dir) = try fixture()
        let source = dir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        var profilesApplied = 0, settingsSaved = 0, starts = 0
        var surface = AppSurface(log: { _ in }, presentError: { _ in }, isSessionRunning: { false },
            applyDetectedProfile: { _ in profilesApplied += 1 }, currentTargetName: { "Test" },
            startSession: { complete in starts += 1; complete(false) }, saveSettings: { settingsSaved += 1 })
        surface.isRestacking = { model.isRestacking }
        let controller = LiveSourceController(surface: surface, relayRoot: dir.appendingPathComponent("relay"))
        defer { controller.stopRelay() }
        if alreadyDetecting {
            controller.startWatchFolderLive(source: source)
            XCTAssertTrue(controller.isDetecting)
        }
        XCTAssertTrue(model.claimRestackPresentation())
        if !alreadyDetecting { controller.startWatchFolderLive(source: source) }
        for _ in 0..<500 where controller.isDetecting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isDetecting, "prerequisite: detection returned to the main actor")
        XCTAssertEqual(profilesApplied, 0)
        XCTAssertEqual(settingsSaved, 0)
        XCTAssertEqual(starts, 0)
    }
}
