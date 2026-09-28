import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class StoreCameraShareTests: XCTestCase {
    // Break caught: cancelled replacement erases the saved grant, or Start prompts
    // again rather than resolving the stored bookmark in a fresh service.
    func testPickerCancelPreservesSavedShareAndRestartReusesIt() throws {
        let suite = "CameraAuthorization.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = CameraBookmarkBackend()
        func locations() -> AuthorizedLocations { AuthorizedLocations(defaults: defaults, policy: .sandboxed, containerRoots: [], backend: backend) }
        let selected = URL(fileURLWithPath: "/chosen-camera")
        let first = CameraShareAuthorization(locations: locations(), choose: { _ in selected })
        XCTAssertEqual(try first.acquire(.seestar)?.url, selected)
        let reopened = CameraShareAuthorization(locations: locations(), choose: { _ in XCTFail("saved grant must avoid picker"); return nil })
        XCTAssertEqual(try reopened.acquire(.seestar)?.url, selected)
        let cancel = CameraShareAuthorization(locations: locations(), choose: { _ in nil })
        XCTAssertNil(try cancel.acquire(.seestar, replacing: true))
        XCTAssertEqual(try reopened.acquire(.seestar)?.url, selected)
        XCTAssertNil(try cancel.acquire(.asiair))
        XCTAssertNil(locations().displayURL(key: "camera:asiair"))
    }

    func testDeniedRememberedShareDoesNotFallBackToPickerOrOtherLocation() throws {
        let suite = "CameraAuthorization.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = CameraBookmarkBackend()
        let locations = AuthorizedLocations(defaults: defaults, policy: .sandboxed, containerRoots: [], backend: backend)
        let share = URL(fileURLWithPath: "/chosen-camera")
        _ = try locations.select(share, key: "camera:asiair")
        backend.denied = true
        let service = CameraShareAuthorization(locations: locations, choose: { _ in XCTFail("denial must not silently replace selection"); return nil })
        XCTAssertThrowsError(try service.acquire(.asiair))
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
        XCTAssertTrue(original!.selectLocation(share, key: seestar ? "camera:seestar" : "camera:asiair"))
        XCTAssertTrue(original!.selectLocation(output, key: "output"))
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
    var entered: Bool { lock.withLock { didEnter } }
    var finished: Bool { lock.withLock { didFinish } }
    let release = DispatchSemaphore(value: 0)
    func check(_ url: URL, forWriting: Bool) throws {
        if forWriting {
            lock.withLock { didEnter = true }
            guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            lock.withLock { didFinish = true }
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
        controller = LiveSourceController(surface: AppSurface(log: { _ in }, presentError: { [weak self] in self?.errors.append($0) },
            isSessionRunning: { false }, applyDetectedProfile: { [weak self] in self?.profiles.append($0) },
            startSession: { _ in XCTFail("sandbox discovery must use authorized start") },
            isSessionStartPending: { [weak self] in self?.pending ?? false },
            acquireOperationAccess: { [weak self] input in
                guard let self else { throw CocoaError(.userCancelled) }
                return OperationFileAccess(input: input, output: self.output, darkPath: nil, flatPath: nil, biasPath: nil,
                    flats: nil, darkFlats: nil, leases: [FileAccessLease(url: self.output), self.operationScopes.lease(input)], availability: self.gate)
            }, acquireCameraShare: { [weak self] _, _ in self.map { $0.rootScopes.lease($0.share) } },
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
        try? FileManager.default.removeItem(at: root)
    }
}
