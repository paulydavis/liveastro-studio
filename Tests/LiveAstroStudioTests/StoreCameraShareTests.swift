import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class StoreCameraShareTests: XCTestCase {
    // Task-local teardown observes the original production Task finishing, not
    // merely the injected permission closure returning before its caller resumes.
    func testLateNilPermissionReplyCannotClearReplacementSearch() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        let old = CameraShareWaiter(), replacement = CameraShareWaiter()
        defer { old.finish(nil); replacement.finish(nil) }
        let retired = expectation(description: "original request task finished")
        rig.acquireShare = { _, _ in try await old.acquire() }
        CameraRequestLifetime.$token.withValue(CameraRequestToken { retired.fulfill() }) {
            rig.controller.startSeestarLive()
        }
        try await rig.wait { old.isWaiting }
        rig.controller.cancelDetection()
        rig.acquireShare = { _, _ in try await replacement.acquire() }
        rig.controller.startASIAIRLive()
        try await rig.wait { replacement.isWaiting }
        old.finish(nil)
        await fulfillment(of: [retired], timeout: 5)
        XCTAssertTrue(rig.controller.isDetecting)
        XCTAssertTrue(rig.controller.canCancelDetection)
        XCTAssertTrue(rig.errors.isEmpty)
        XCTAssertTrue(rig.profiles.isEmpty)
        rig.controller.cancelDetection()
        replacement.finish(nil)
    }

    func testCancelSearchDoesNotReleaseAlreadyStartedRelayAccess() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.gate.release.signal()
        try await rig.wait { rig.startedAccess != nil }
        rig.startCompletion?(true)
        rig.startCompletion = nil
        rig.startedAccess = nil
        try await rig.wait { rig.rootScopes.active == 0 }
        let scopeCount = rig.operationScopes.active
        XCTAssertGreaterThan(scopeCount, 0)
        XCTAssertFalse(rig.controller.canCancelDetection)
        rig.controller.cancelDetection()
        XCTAssertEqual(rig.operationScopes.active, scopeCount)
        XCTAssertFalse(rig.controller.isDetecting)
        XCTAssertFalse(rig.controller.isStarting)
        // Only production now owns this grant. Real teardown releases it, whereas
        // a stale UI cancel action must not. No test-held access can mask release.
        rig.controller.stopRelay()
        try await rig.wait { rig.operationScopes.active == 0 }
    }

    // A no-op Cancel leaves the UI busy and allows the parked result to start.
    func testUserCancelRetiresSearchButKeepsBlockedReadAccessAlive() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        XCTAssertTrue(rig.controller.canCancelDetection)
        rig.controller.cancelDetection()
        XCTAssertFalse(rig.controller.isDetecting)
        XCTAssertFalse(rig.controller.canCancelDetection)
        XCTAssertEqual(rig.rootScopes.active, 1)
        XCTAssertEqual(rig.operationScopes.active, 1)
        rig.gate.release.signal()
        try await rig.wait { rig.rootScopes.active == 0 && rig.operationScopes.active == 0 }
        XCTAssertTrue(rig.profiles.isEmpty)
        XCTAssertNil(rig.startedAccess)
        XCTAssertTrue(rig.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.relay.path))
    }

    // Removing generation checks lets an old error retire a newer pending request.
    func testCancelledReadFailureCannotRetireReplacementSearch() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.controller.cancelDetection()
        let replacement = CameraShareWaiter()
        rig.acquireShare = { _, _ in try await replacement.acquire() }
        rig.controller.startASIAIRLive()
        try await rig.wait { replacement.isWaiting }
        defer { replacement.finish(nil) }
        rig.gate.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file Macintosh HD could not be opened."])
        rig.gate.release.signal()
        try await rig.wait { rig.rootScopes.active == 0 && rig.operationScopes.active == 0 }
        XCTAssertTrue(rig.controller.isDetecting, "old failure must not clear replacement ownership")
        XCTAssertTrue(rig.controller.canCancelDetection)
        XCTAssertTrue(rig.errors.isEmpty)
        XCTAssertTrue(rig.profiles.isEmpty)
        replacement.finish(nil)
        try await rig.wait { !rig.controller.isDetecting }
    }

    func testPermissionCancellationAllowsRetryWithoutLateStart() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        let permission = CameraShareWaiter()
        defer { permission.finish(nil) }
        rig.acquireShare = { _, _ in try await permission.acquire() }
        rig.controller.startSeestarLive()
        try await rig.wait { permission.isWaiting }
        rig.controller.cancelDetection()
        XCTAssertFalse(rig.controller.isDetecting)
        rig.acquireShare = nil
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        permission.finish(rig.rootScopes.lease(rig.share))
        try await rig.wait { rig.rootScopes.active == 1 }
        XCTAssertTrue(rig.controller.isDetecting)
        XCTAssertTrue(rig.profiles.isEmpty)
        rig.gate.release.signal()
        try await rig.wait { rig.startedAccess != nil }
        XCTAssertEqual(rig.profiles.filter { $0.targetName != nil }.count, 1)
    }

    func testCameraPermissionErrorNamesCameraAndKeepsTechnicalDetailInLog() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.acquireShare = { _, _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "Macintosh HD unavailable"] ) }
        rig.controller.startASIAIRLive()
        try await rig.wait { !rig.errors.isEmpty }
        XCTAssertTrue(rig.errors[0].contains("ASIAIR"))
        XCTAssertTrue(rig.errors[0].contains("permission"))
        XCTAssertFalse(rig.errors[0].contains("Macintosh HD"))
        XCTAssertTrue(rig.logs.contains { $0.contains("Macintosh HD") })
        XCTAssertFalse(rig.controller.isDetecting)
    }

    func testCameraDiscoveryErrorIsNotReportedAsSessionFolderFailure() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        // A missing selected share exercises the real detector's listing error.
        rig.acquireShare = { _, _ in rig.rootScopes.lease(rig.root.appendingPathComponent("missing-share")) }
        rig.controller.startSeestarLive()
        try await rig.wait { !rig.errors.isEmpty }
        XCTAssertTrue(rig.errors[0].contains("Seestar"))
        XCTAssertTrue(rig.errors[0].contains("searching"))
        XCTAssertFalse(rig.errors[0].contains("calibration"))
        XCTAssertFalse(rig.controller.isDetecting)
    }

    func testCameraSessionFolderFailureDoesNotBlameCameraSearch() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.gate.failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "Macintosh HD unavailable"])
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.gate.release.signal()
        try await rig.wait { !rig.errors.isEmpty }
        XCTAssertTrue(rig.errors[0].contains("Seestar"))
        XCTAssertTrue(rig.errors[0].contains("session folders"))
        XCTAssertFalse(rig.errors[0].contains("Macintosh HD"))
        XCTAssertTrue(rig.logs.contains { $0.contains("Macintosh HD") })
        XCTAssertNil(rig.startedAccess)
    }

    // Break caught: cancelled replacement erases the saved grant, or Start prompts
    // again rather than resolving the stored bookmark in a fresh service.
    func testPickerCancelPreservesSavedShareAndRestartReusesIt() async throws {
        let suite = "CameraAuthorization.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = CameraBookmarkBackend()
        func locations() -> AuthorizedLocations { AuthorizedLocations(defaults: defaults, policy: .sandboxed, containerRoots: [], backend: backend) }
        let selected = URL(fileURLWithPath: "/chosen-camera")
        let first = CameraShareAuthorization(locations: locations(), choose: { _ in selected })
        await assertAccessEqual(try await first.acquire(.seestar)?.url, selected)
        let reopened = CameraShareAuthorization(locations: locations(), choose: { _ in XCTFail("saved grant must avoid picker"); return nil })
        await assertAccessEqual(try await reopened.acquire(.seestar)?.url, selected)
        let cancel = CameraShareAuthorization(locations: locations(), choose: { _ in nil })
        await assertAccessNil(try await cancel.acquire(.seestar, replacing: true))
        await assertAccessEqual(try await reopened.acquire(.seestar)?.url, selected)
        await assertAccessNil(try await cancel.acquire(.asiair))
        XCTAssertNil(locations().displayURL(key: "camera:asiair"))
    }

    func testDeniedRememberedShareDoesNotFallBackToPickerOrOtherLocation() async throws {
        let suite = "CameraAuthorization.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = CameraBookmarkBackend()
        let locations = AuthorizedLocations(defaults: defaults, policy: .sandboxed, containerRoots: [], backend: backend)
        let share = URL(fileURLWithPath: "/chosen-camera")
        _ = try await locations.select(share, key: "camera:asiair")
        backend.denied = true
        let service = CameraShareAuthorization(locations: locations, choose: { _ in XCTFail("denial must not silently replace selection"); return nil })
        await assertAccessThrows(try await service.acquire(.asiair))
        XCTAssertEqual(locations.displayURL(key: "camera:asiair")?.path, share.path)
    }

    func testManualStartPendingDuringDiscoveryPreventsProfileAndRelayChanges() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.pending = true
        rig.gate.release.signal()
        try await rig.wait { !rig.controller.isDetecting }
        XCTAssertTrue(rig.profiles.isEmpty)
        XCTAssertNil(rig.startedAccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.relay.path))
    }

    func testStopDuringDiscoveryInvalidatesItsLateCompletion() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.controller.stopRelay()
        XCTAssertEqual(rig.rootScopes.active, 1, "cancellation must not revoke a parked worker's root grant")
        XCTAssertEqual(rig.operationScopes.active, 1)
        rig.gate.release.signal()
        try await rig.wait { rig.rootScopes.active == 0 && rig.operationScopes.active == 0 }
        XCTAssertTrue(rig.profiles.isEmpty)
        XCTAssertNil(rig.startedAccess)
        XCTAssertFalse(rig.controller.isDetecting)
    }

    func testAuthorizedRelayStartCapturesAccessAndCancelRetiresIt() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.gate.release.signal()
        try await rig.wait { rig.startedAccess != nil }
        XCTAssertTrue(rig.controller.isStarting)
        XCTAssertEqual(rig.startedAccess?.output, rig.output)
        XCTAssertTrue(rig.startedAccess?.input.path.hasPrefix(rig.relay.path + "/") == true)
        XCTAssertEqual(rig.profiles.first?.targetName, "M 31")
        XCTAssertEqual(rig.profiles.first?.fileNamePrefix, "Light_")
        XCTAssertEqual(rig.operationScopes.active, 1)
        rig.startCompletion?(false)
        rig.startedAccess = nil
        rig.startCompletion = nil
        try await rig.wait { rig.operationScopes.active == 0 && rig.rootScopes.active == 0 }
        XCTAssertFalse(rig.controller.isStarting)
    }

    func testRelayCreationFailureReleasesOperationPermissions() async throws {
        let rig = try CameraControllerRig()
        defer { rig.close() }
        // A file where the relay directory must go forces the real relay.start() to fail.
        try Data("not a directory".utf8).write(to: rig.relay)
        rig.controller.startSeestarLive()
        try await rig.wait { rig.gate.entered }
        rig.gate.release.signal()
        try await rig.wait { !rig.errors.isEmpty && rig.rootScopes.active == 0 }
        XCTAssertEqual(rig.operationScopes.active, 0)
        XCTAssertNil(rig.startedAccess)
        XCTAssertFalse(rig.controller.isStarting)
    }

    // Break caught: preview Start still refuses discovery or scans a parent instead
    // of the saved share. Real detectors/relay/start run; only macOS bookmarks are faked.
    func testSeestarStartsFromRememberedShareAfterModelRestart() async throws {
        try await checkStart(seestar: true)
    }

    func testASIAIRStartsFromRememberedShareAfterModelRestart() async throws {
        try await checkStart(seestar: false)
    }

    private func checkStart(seestar: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let share = root.appendingPathComponent("chosen-share")
        let target = share.appendingPathComponent(seestar ? "MyWorks/M 31_sub" : "Autorun/Light/M 31")
        let output = root.appendingPathComponent("output")
        for url in [target, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var metadata = SourceMetadata(); metadata.object = "M 31"; metadata.exposureSeconds = 30
        try FITSWriter.float32(width: 8, height: 8, channels: 1,
            pixels: [Float](repeating: 0.1, count: 64), metadata: metadata)
            .write(to: target.appendingPathComponent("Light_M 31_30.0s_IRCUT_20260927-010000.fit"))
        let suite = "StoreCameraShareTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let backend = CameraBookmarkBackend()
        let configuration = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview",
                                                       containerRoot: root.appendingPathComponent("container"))
        func makeModel() -> AppModel {
            AppModel(userDefaults: defaults,
                     calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("container/library")),
                     configuration: configuration, bookmarkBackend: backend)
        }
        var original: AppModel? = makeModel()
        await assertAccessTrue(await original!.selectLocation(share, key: seestar ? "camera:seestar" : "camera:asiair"))
        await assertAccessTrue(await original!.selectLocation(output, key: "output"))
        original = nil
        let model = makeModel()
        if seestar { model.liveSource.startSeestarLive() } else { model.liveSource.startASIAIRLive() }
        let deadline = Date().addingTimeInterval(10)
        while (model.liveSource.isDetecting || model.isPreparingSessionInput) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.liveSource.isDetecting, "discovery prerequisite timed out")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.targetName, "M 31")
        XCTAssertEqual(model.fileNamePrefix, seestar ? "Light_" : "")
        XCTAssertTrue(model.watchFolder?.path.hasPrefix(configuration.relayRoot.path + "/") == true)
        XCTAssertTrue(model.isRunning || model.hasPendingSessionStart, "must reach the actual session start flow")
        if model.hasPendingSessionStart { model.resolvePendingSessionStart(.cancel) }
        if model.isRunning { model.endSession() }
        model.liveSource.stopRelay()
        let endDeadline = Date().addingTimeInterval(15)
        while model.isRunning && Date() < endDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRunning, "test session must finish before removing its files")
    }
}

private final class CameraBookmarkBackend: BookmarkAccessing, @unchecked Sendable {
    var denied = false
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool { !denied }
    func stopAccessing(_ url: URL) {}
}

private final class CameraAvailabilityGate: LocationAvailabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false, didFinish = false
    private var storedFailure: NSError?
    var failure: NSError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    var entered: Bool { lock.withLock { didEnter } }
    var finished: Bool { lock.withLock { didFinish } }
    let release = DispatchSemaphore(value: 0)
    func check(_ url: URL, forWriting: Bool) throws {
        if forWriting {
            lock.withLock { didEnter = true }
            guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            lock.withLock { didFinish = true }
            if let failure { throw failure }
        }
        try FileLocationAvailability().check(url, forWriting: forWriting)
    }
}

private final class CameraScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var active: Int { lock.withLock { count } }
    func lease(_ url: URL) -> FileAccessLease {
        lock.withLock { count += 1 }
        return FileAccessLease(url: url) { [self] in lock.withLock { count -= 1 } }
    }
}

@MainActor
private final class CameraControllerRig {
    let root: URL, share: URL, output: URL, relay: URL
    let gate = CameraAvailabilityGate()
    let rootScopes = CameraScopeCounter(), operationScopes = CameraScopeCounter()
    var pending = false
    var errors: [String] = []
    var logs: [String] = []
    var acquireShare: ((CameraShareKind, Bool) async throws -> FileAccessLease?)?
    var profiles: [DetectedProfile] = []
    var startedAccess: OperationFileAccess?
    var startCompletion: ((Bool) -> Void)?
    var controller: LiveSourceController!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        share = root.appendingPathComponent("share")
        output = root.appendingPathComponent("output")
        relay = root.appendingPathComponent("relay")
        for url in [share.appendingPathComponent("MyWorks/M 31_sub"), output] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        controller = LiveSourceController(surface: AppSurface(log: { [weak self] in self?.logs.append($0) }, presentError: { [weak self] in self?.errors.append($0) },
            isSessionRunning: { false }, applyDetectedProfile: { [weak self] in self?.profiles.append($0) },
            startSession: { _ in XCTFail("sandbox discovery must use authorized start") },
            isSessionStartPending: { [weak self] in self?.pending ?? false },
            acquireOperationAccess: { [weak self] input in
                guard let self else { throw CocoaError(.userCancelled) }
                return OperationFileAccess(input: input, output: self.output, darkPath: nil, flatPath: nil, biasPath: nil,
                    flats: nil, darkFlats: nil, leases: [FileAccessLease(url: self.output), self.operationScopes.lease(input)], availability: self.gate)
            }, acquireCameraShare: { [weak self] kind, replacing in
                guard let self else { return nil }
                if let acquireShare = self.acquireShare { return try await acquireShare(kind, replacing) }
                return self.rootScopes.lease(self.share)
            },
            startAuthorizedSession: { [weak self] access, completion in
                self?.startedAccess = access; self?.startCompletion = completion
            }, isStorePreview: true), relayRoot: relay)
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "required controller boundary was not reached")
        if !condition() { throw CocoaError(.userCancelled) }
    }

    func close() {
        gate.release.signal()
        controller.stopRelay()
        acquireShare = nil
        startedAccess = nil
        startCompletion = nil
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class CameraShareWaiter {
    private var continuation: CheckedContinuation<FileAccessLease?, Error>?
    var isWaiting: Bool { continuation != nil }
    func acquire() async throws -> FileAccessLease? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ lease: FileAccessLease?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: lease)
    }
}

private enum CameraRequestLifetime {
    @TaskLocal static var token: CameraRequestToken?
}

private final class CameraRequestToken: @unchecked Sendable {
    private let finished: @Sendable () -> Void
    init(_ finished: @escaping @Sendable () -> Void) { self.finished = finished }
    deinit { finished() }
}
