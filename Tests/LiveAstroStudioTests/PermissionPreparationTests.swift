import Foundation
import XCTest
import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class PermissionPreparationTests: XCTestCase {
    func testOutputArtifactProbeRunsOffMainAndRetainsAccessThroughCancellation() async throws {
        let (model, backend, root) = try await modelFixture()
        let probe = ArtifactProbe()
        let task = Task { try await model.sessionArtifactNames(in: root, scan: { try probe.scan($0) }) }
        await fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertFalse(probe.ranOnMain, "SwiftUI must read cached availability, not wait for filesystem I/O")
        XCTAssertEqual(backend.balance, 1)
        task.cancel()
        XCTAssertEqual(backend.balance, 1, "cancellation must not revoke an in-flight filesystem read")
        probe.release.signal()
        do { _ = try await task.value; XCTFail("cancelled availability must not publish") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(backend.balance, 0)
        let names = try await model.sessionArtifactNames(in: root)
        XCTAssertTrue(names.isEmpty)
        try Data("summary".utf8).write(to: root.appendingPathComponent("session-summary.md"))
        let refreshed = try await model.sessionArtifactNames(in: root)
        XCTAssertEqual(refreshed, ["session-summary.md"])
    }
    func testExplicitSelectionWinsOverConcurrentOldGrantRenewal() async throws {
        let (store, backend, _) = try fixture()
        let old = URL(fileURLWithPath: "/permission-test/old")
        let moved = URL(fileURLWithPath: "/permission-test/old-moved")
        let chosen = URL(fileURLWithPath: "/permission-test/chosen")
        _ = try await store.select(old, key: "output")
        backend.move(from: old, to: moved)
        backend.arm(.create)
        let selection = Task { try await store.select(chosen, key: "output") }
        await fulfillment(of: [backend.entered], timeout: 5)
        _ = try await store.acquire(key: "output")
        backend.release.signal()
        let lease = try await selection.value
        XCTAssertEqual(lease.url.path, chosen.path)
        XCTAssertEqual(store.displayURL(key: "output")?.path, chosen.path,
                       "reported selection and persisted grant must agree")
        await assertAccessEqual(try await store.acquire(key: "output").url.path, chosen.path)
    }
    func testImportCancelledDuringBookmarkResolutionNeverAdmitsWork() async throws {
        let (model, backend, root) = try await modelFixture()
        backend.arm(.resolve)
        model.importer.importSubs(from: root)
        await fulfillment(of: [backend.entered], timeout: 5)
        model.importer.cancelImport()
        XCTAssertFalse(model.importer.isImporting)
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        try await waitUntil { backend.balance == 0 }
        XCTAssertNil(model.lastSessionDirectory)
        XCTAssertNil(model.errorMessage)
    }

    func testCameraCancelledDuringBookmarkResolutionDoesNotReportLateDiscoveryError() async throws {
        let (model, backend, root) = try await modelFixture()
        await assertAccessTrue(await model.selectLocation(root, key: "camera:seestar"))
        backend.arm(.resolve)
        model.liveSource.startSeestarLive()
        await fulfillment(of: [backend.entered], timeout: 5)
        model.liveSource.stopRelay()
        XCTAssertFalse(model.liveSource.isDetecting)
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        try await waitUntil { backend.balance == 0 }
        XCTAssertNil(model.lastSessionDirectory)
        XCTAssertNil(model.errorMessage)
    }

    func testCalibrationSelectionChangeDuringResolutionDoesNotBuildOldSource() async throws {
        let (model, backend, root) = try await modelFixture()
        backend.arm(.resolve)
        model.addMasterFromFolder(root, kind: .bias)
        await fulfillment(of: [backend.entered], timeout: 5)
        await model.setCalibrationFolder(nil, darkFlats: true)
        XCTAssertFalse(model.calibrationBusy, "reselection must retire preparation before blocked OS work returns")
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        try await waitUntil { backend.balance == 0 }
        XCTAssertTrue(model.calibrationLibrary.all().isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(backend.balance, 0)
    }

    func testRestorationCannotOverwriteSelectionMadeWhileResolutionIsBlocked() async throws {
        let (model, backend, root) = try await modelFixture()
        backend.arm(.resolve)
        model.restoreAuthorizedSelections()
        await fulfillment(of: [backend.entered], timeout: 5)
        let new = root.appendingPathComponent("new-choice")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        await assertAccessTrue(await model.selectLocation(new, key: "capture"))
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        try await waitUntil { backend.balance == 0 }
        XCTAssertEqual(model.watchFolder?.path, new.path)
        XCTAssertNil(model.errorMessage)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard condition() else { XCTFail("permission worker did not finish"); throw CancellationError() }
    }

    private func modelFixture() async throws -> (AppModel, PermissionGateBackend, URL) {
        let suite = "PermissionModelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = PermissionGateBackend()
        addTeardownBlock { backend.release.signal(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(userDefaults: defaults,
                             calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")),
                             configuration: StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview", containerRoot: root.appendingPathComponent("container")),
                             bookmarkBackend: backend)
        await assertAccessTrue(await model.selectLocation(root, key: "capture"))
        await assertAccessTrue(await model.selectLocation(root, key: "output"))
        return (model, backend, root)
    }

    func testDemoPermissionPreparationCanBeCancelledBeforeItChangesSettings() async throws {
        let suite = "PermissionDemoTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = PermissionGateBackend()
        defer { backend.release.signal(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(userDefaults: defaults,
                             configuration: StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview", containerRoot: root.appendingPathComponent("container")),
                             bookmarkBackend: backend)
        await assertAccessTrue(await model.selectLocation(root, key: "output"))
        model.targetName = "Keep this target"
        backend.arm(.resolve)
        model.startDemoSession()
        await fulfillment(of: [backend.entered], timeout: 5)
        XCTAssertTrue(model.hasPendingSessionStart, "Demo must own preparation before permission I/O")
        model.cancelSessionInputPreparation()
        XCTAssertFalse(model.hasPendingSessionStart)
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.targetName, "Keep this target")
        XCTAssertFalse(model.isRunning)
        model.cancelSessionInputPreparation()
        if model.isRunning { model.endSession() }
    }

    func testUnavailablePostProcessingClearsItsBusyState() async throws {
        let suite = "PermissionProcessingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(userDefaults: defaults)
        model.processorBackend = .none
        model.importer.processMaster(sessionDirectory: URL(fileURLWithPath: "/nonexistent-session"))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(model.importer.isProcessing)
    }

    func testCancelledResolutionCannotPublishRenewalAndBalancesScope() async throws {
        let (store, backend, defaults) = try fixture()
        let old = URL(fileURLWithPath: "/permission-test/old")
        _ = try await store.select(old, key: "capture")
        let before = defaults.data(forKey: AuthorizedLocations.defaultsKey)
        backend.move(to: URL(fileURLWithPath: "/permission-test/new"))
        backend.arm(.resolve)
        let task = Task { try await store.acquire(key: "capture") }
        await fulfillment(of: [backend.entered], timeout: 5)
        XCTAssertFalse(backend.ranOnMain)
        task.cancel()
        backend.release.signal()
        do { _ = try await task.value; XCTFail("cancelled permission request returned access") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
        XCTAssertEqual(backend.balance, 0)
    }

    func testNewSelectionWinsAgainstBlockedOlderSelection() async throws {
        let (store, backend, _) = try fixture()
        let old = URL(fileURLWithPath: "/permission-test/old"), new = URL(fileURLWithPath: "/permission-test/new")
        backend.arm(.create)
        let first = Task { try await store.select(old, key: "capture") }
        await fulfillment(of: [backend.entered], timeout: 5)
        XCTAssertFalse(backend.ranOnMain)
        _ = try await store.select(new, key: "capture")
        backend.release.signal()
        do { _ = try await first.value; XCTFail("obsolete selection returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.displayURL(key: "capture")?.path, new.path)
        XCTAssertEqual(backend.balance, 0)
    }

    func testCancelledRenewalReleasesAlreadyAcquiredScope() async throws {
        let (store, backend, defaults) = try fixture()
        _ = try await store.select(URL(fileURLWithPath: "/permission-test/old"), key: "capture")
        let before = defaults.data(forKey: AuthorizedLocations.defaultsKey)
        backend.move(to: URL(fileURLWithPath: "/permission-test/new"))
        backend.arm(.create)
        let task = Task { try await store.acquire(key: "capture") }
        await fulfillment(of: [backend.entered], timeout: 5)
        XCTAssertEqual(backend.balance, 1, "scope must survive the blocked renewal")
        XCTAssertFalse(backend.ranOnMain)
        task.cancel()
        XCTAssertEqual(backend.balance, 1)
        backend.release.signal()
        do { _ = try await task.value; XCTFail("cancelled renewal returned access") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(backend.balance, 0)
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
    }

    func testContainmentCheckLeavesMainActorAvailableAndCancellationWins() async throws {
        let gate = PermissionGateBackend()
        let suite = "PermissionContainmentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); gate.release.signal() }
        let store = AuthorizedLocations(defaults: defaults, policy: .sandboxed,
                                        containerRoots: [URL(fileURLWithPath: "/permission-test")],
                                        backend: gate, canonicalizer: gate)
        gate.arm(.canonicalize)
        let task = Task { try await store.acquire(url: URL(fileURLWithPath: "/permission-test/child")) }
        await fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertFalse(gate.ranOnMain)
        task.cancel()
        gate.release.signal()
        do { _ = try await task.value; XCTFail("cancelled containment request returned access") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.balance, 0)
    }

    func testStartCancellationBeforeAvailabilityCompletesOnceAndDoesNotStart() async throws {
        let suite = "PermissionStartTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = PermissionGateBackend()
        defer { backend.release.signal(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(userDefaults: defaults,
                             calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")),
                             configuration: StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview",
                                                                      containerRoot: root.appendingPathComponent("container")),
                             bookmarkBackend: backend)
        await assertAccessTrue(await model.selectLocation(root, key: "capture"))
        await assertAccessTrue(await model.selectLocation(root, key: "output"))
        backend.arm(.resolve)
        var completions: [Bool] = []
        model.startSession { completions.append($0) }
        XCTAssertTrue(model.isPreparingSessionInput)
        await fulfillment(of: [backend.entered], timeout: 5)
        model.cancelSessionInputPreparation()
        XCTAssertEqual(completions, [false])
        XCTAssertFalse(model.hasPendingSessionStart)
        backend.release.signal()
        await fulfillment(of: [backend.returned], timeout: 5)
        // Drain actor work without blocking it; the task checks cancellation before publication.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(completions, [false])
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.errorMessage)
    }

    private func fixture() throws -> (AuthorizedLocations, PermissionGateBackend, UserDefaults) {
        let suite = "PermissionPreparationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let backend = PermissionGateBackend()
        addTeardownBlock { backend.release.signal(); defaults.removePersistentDomain(forName: suite) }
        return (AuthorizedLocations(defaults: defaults, policy: .sandboxed, containerRoots: [], backend: backend), backend, defaults)
    }
}

private final class ArtifactProbe: @unchecked Sendable {
    let entered = XCTestExpectation(description: "output existence probe")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var main = false
    var ranOnMain: Bool { lock.withLock { main } }
    func scan(_ directory: URL) throws -> Set<String> {
        lock.withLock { main = Thread.isMainThread }
        entered.fulfill()
        if !Thread.isMainThread { _ = release.wait(timeout: .now() + 10) }
        return ["master.fit"]
    }
}

/// The main-thread mutation fails without parking the test runner. Production
/// authorization, persistence and lease cleanup stay real; only OS calls are faked.
private final class PermissionGateBackend: BookmarkAccessing, LocationCanonicalizing, @unchecked Sendable {
    enum Stage { case create, resolve, canonicalize }
    let entered = XCTestExpectation(description: "blocked permission boundary entered")
    let returned = XCTestExpectation(description: "blocked permission boundary returned")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stage: Stage?
    private var moved: URL?
    private var movedFrom: URL?
    private var scopes = 0
    private var main = false
    var balance: Int { lock.withLock { scopes } }
    var ranOnMain: Bool { lock.withLock { main } }
    func arm(_ stage: Stage) { lock.withLock { self.stage = stage } }
    func move(from old: URL? = nil, to url: URL) { lock.withLock { movedFrom = old; moved = url } }
    private func park(_ stage: Stage) {
        let shouldPark = lock.withLock { () -> Bool in
            guard self.stage == stage else { return false }
            self.stage = nil
            main = Thread.isMainThread
            return true
        }
        guard shouldPark else { return }
        entered.fulfill()
        if !Thread.isMainThread { _ = release.wait(timeout: .now() + 10) }
        returned.fulfill()
    }
    func createBookmark(for url: URL) throws -> Data { park(.create); return Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        park(.resolve)
        let old = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
        return lock.withLock {
            let result = movedFrom == nil || movedFrom?.path == old.path ? moved : nil
            return BookmarkResolution(url: result ?? old, isStale: result != nil)
        }
    }
    func canonicalURL(_ url: URL) -> URL { park(.canonicalize); return url.standardizedFileURL }
    func startAccessing(_ url: URL) -> Bool { lock.withLock { scopes += 1 }; return true }
    func stopAccessing(_ url: URL) { lock.withLock { scopes -= 1 } }
}
