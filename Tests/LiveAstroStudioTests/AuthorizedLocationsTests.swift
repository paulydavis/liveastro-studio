import Foundation
import XCTest
@testable import LiveAstroStudio

@MainActor
final class AuthorizedLocationsTests: XCTestCase {
    func testHealthyCoveringGrantDoesNotResolveUnrelatedDeeperBookmark() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let store = makeStore(defaults, backend)
        let unrelated = temporaryURL("offline/deeper/folder"), wanted = temporaryURL("wanted")
        _ = try await store.select(unrelated, key: "unrelated")
        _ = try await store.select(wanted, key: "wanted")
        let bookmarks = backend.createdBookmarks
        let prior = backend.resolvedBookmarks.count
        _ = try await store.acquire(url: wanted)
        XCTAssertEqual(Array(backend.resolvedBookmarks.dropFirst(prior)), [bookmarks[1]],
                       "a healthy explicit grant must not wait on an unrelated share")
    }
    func testBookmarkPreparationDoesNotRunOnMainThread() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let store = makeStore(defaults, backend)
        let original = temporaryURL("original"), moved = temporaryURL("moved")
        _ = try await store.select(original, key: "capture")
        let bookmark = try XCTUnwrap(backend.createdBookmarks.first)
        backend.resolutions[bookmark] = BookmarkResolution(url: moved, isStale: true)
        _ = try await store.acquire(key: "capture")
        XCTAssertFalse(backend.preparationThreads.isEmpty)
        XCTAssertFalse(backend.preparationThreads.contains(true),
                       "permission preparation must not perform bookmark I/O on main")
    }
    func testFailedStaleRenewalPreservesBytesAndLastOwnerStopsMovedScope() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let original = temporaryURL("original"), moved = temporaryURL("moved")
        let store = makeStore(defaults, backend)
        _ = try await store.select(original, key: "capture")
        let before = try XCTUnwrap(defaults.data(forKey: AuthorizedLocations.defaultsKey))
        let bookmark = try XCTUnwrap(backend.createdBookmarks.first)
        backend.resolutions[bookmark] = BookmarkResolution(url: moved, isStale: true)
        backend.deniedCreates.insert(moved.standardizedFileURL)
        var lease: FileAccessLease? = try await store.acquire(key: "capture")
        var workerOwner = lease
        XCTAssertEqual(lease?.url.path, moved.path)
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
        XCTAssertEqual(store.displayURL(key: "capture")?.path, original.path)
        lease = nil
        XCTAssertEqual(workerOwner?.url.path, moved.path)
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == moved.path }.count, 0)
        workerOwner = nil
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == moved.path }.count, 1)
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
    }
    func testGroupUsesOriginalMovedParentOnlyWithinItsAcquisition() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let original = temporaryURL("original"), moved = temporaryURL("moved")
        let store = makeStore(defaults, backend)
        _ = try await store.select(original, key: "masters")
        let bookmark = try XCTUnwrap(backend.createdBookmarks.first)
        backend.resolutions[bookmark] = BookmarkResolution(url: moved, isStale: true)
        var results: [Result<FileAccessLease, Error>]? = await store.acquireGroup([
            .url(original.appendingPathComponent("dark.fit")), .url(original.appendingPathComponent("flat.fit"))])
        XCTAssertEqual(try results?[0].get().url.path, moved.appendingPathComponent("dark.fit").path)
        XCTAssertEqual(try results?[1].get().url.path, moved.appendingPathComponent("flat.fit").path)
        XCTAssertEqual(store.displayURL(key: "masters")?.path, moved.path)
        results = nil
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == moved.path }.count, 2)
        await assertAccessThrows(try await store.acquire(url: original.appendingPathComponent("replacement.fit")))
        await assertAccessEqual(try await store.acquire(url: moved.appendingPathComponent("flat.fit")).url.path,
                       moved.appendingPathComponent("flat.fit").path)
    }

    func testGroupFailuresKeepRecordsAndSuccessfulLeasesBalanceIndependently() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let output = temporaryURL("output"), input = temporaryURL("input")
        let store = makeStore(defaults, backend)
        _ = try await store.select(output, key: "output")
        _ = try await store.select(input, key: "capture")
        let before = defaults.data(forKey: AuthorizedLocations.defaultsKey)
        backend.deniedStarts.insert(output.standardizedFileURL)
        var results: [Result<FileAccessLease, Error>]? = await store.acquireGroup([
            .key("output"), .url(input), .url(temporaryURL("not-authorized"))])
        XCTAssertThrowsError(try results?[0].get()) {
            guard case .accessDenied = $0 as? AuthorizedLocationError else { return XCTFail("output failure must remain first") }
        }
        XCTAssertEqual(try results?[1].get().url.path, input.path)
        XCTAssertThrowsError(try results?[2].get())
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == input.path }.count, 1)
        results = nil
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == input.path }.count, 2)
        XCTAssertEqual(backend.stoppedURLs.filter { $0.path == output.path }.count, 1, "denied starts are never stopped")
    }
    func testFreshStoreRestoresPersistedGrant() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let input = temporaryURL("capture")
        var selected: FileAccessLease? = try await makeStore(defaults, backend).select(input, key: "capture")
        XCTAssertEqual(selected?.url, input.standardizedFileURL)
        selected = nil

        let reopened = makeStore(defaults, backend)
        var restored: FileAccessLease? = try await reopened.acquire(key: "capture")
        XCTAssertEqual(restored?.url, input.standardizedFileURL)
        restored = nil

        XCTAssertEqual(backend.startedURLs, [input.standardizedFileURL, input.standardizedFileURL])
        XCTAssertEqual(backend.stoppedURLs, [input.standardizedFileURL, input.standardizedFileURL])
    }

    func testStaleGrantRenewsAfterAccessAndUsesMovedURL() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let original = temporaryURL("original")
        let moved = temporaryURL("moved")
        var selected: FileAccessLease? = try await makeStore(defaults, backend).select(original, key: "capture")
        XCTAssertEqual(selected?.url, original.standardizedFileURL)
        selected = nil
        let oldBookmark = try XCTUnwrap(backend.createdBookmarks.first)
        backend.resolutions[oldBookmark] = BookmarkResolution(url: moved, isStale: true)

        var restored: FileAccessLease? = try await makeStore(defaults, backend).acquire(key: "capture")
        XCTAssertEqual(restored?.url, moved.standardizedFileURL)
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "capture"), moved.standardizedFileURL)
        XCTAssertEqual(backend.createdURLs, [original.standardizedFileURL, moved.standardizedFileURL])
        XCTAssertEqual(backend.events.suffix(2), [.start(moved.standardizedFileURL), .create(moved.standardizedFileURL)])
        restored = nil
        XCTAssertEqual(backend.stoppedURLs.last, moved.standardizedFileURL)
    }

    func testDeniedResolutionPreservesPersistedRecordAndDisplayPath() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let input = temporaryURL("denied")
        var selected: FileAccessLease? = try await makeStore(defaults, backend).select(input, key: "capture")
        XCTAssertEqual(selected?.url, input.standardizedFileURL)
        selected = nil
        let bookmark = try XCTUnwrap(backend.createdBookmarks.first)
        let storedBefore = try XCTUnwrap(defaults.data(forKey: AuthorizedLocations.defaultsKey))
        backend.deniedResolutions.insert(bookmark)

        await assertAccessThrows(try await makeStore(defaults, backend).acquire(key: "capture"))
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), storedBefore)
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "capture"), input.standardizedFileURL)
    }

    func testFailedReplacementPreservesOldGrantAndDoesNotStopHeldLease() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let oldURL = temporaryURL("old")
        let newURL = temporaryURL("new")
        var held: FileAccessLease? = try await makeStore(defaults, backend).select(oldURL, key: "output")
        backend.deniedCreates.insert(newURL.standardizedFileURL)

        await assertAccessThrows(try await makeStore(defaults, backend).select(newURL, key: "output"))
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "output"), oldURL.standardizedFileURL)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
        XCTAssertEqual(held?.url, oldURL.standardizedFileURL)

        held = nil
        XCTAssertEqual(backend.stoppedURLs, [oldURL.standardizedFileURL])
    }

    func testReplacingSelectionLeavesBothOperationLeasesIndependentlyOwned() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let firstURL = temporaryURL("first")
        let secondURL = temporaryURL("second")
        let store = makeStore(defaults, backend)
        var first: FileAccessLease? = try await store.select(firstURL, key: "capture")
        var second: FileAccessLease? = try await store.select(secondURL, key: "capture")

        XCTAssertEqual(first?.url, firstURL.standardizedFileURL)
        XCTAssertEqual(second?.url, secondURL.standardizedFileURL)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
        XCTAssertEqual(store.displayURL(key: "capture"), secondURL.standardizedFileURL)

        second = nil
        XCTAssertEqual(backend.stoppedURLs, [secondURL.standardizedFileURL])
        XCTAssertEqual(first?.url, firstURL.standardizedFileURL)
        first = nil
        XCTAssertEqual(Set(backend.stoppedURLs), Set([firstURL.standardizedFileURL, secondURL.standardizedFileURL]))
    }

    func testOnlySuccessfulStartsAreBalancedByStops() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let allowed = temporaryURL("allowed")
        let denied = temporaryURL("denied")
        var lease: FileAccessLease? = try await makeStore(defaults, backend).select(allowed, key: "capture")
        XCTAssertEqual(lease?.url, allowed.standardizedFileURL)
        backend.deniedStarts.insert(denied.standardizedFileURL)

        await assertAccessThrows(try await makeStore(defaults, backend).select(denied, key: "output"))
        XCTAssertEqual(backend.stoppedURLs, [])
        lease = nil
        XCTAssertEqual(backend.startedURLs, [allowed.standardizedFileURL, denied.standardizedFileURL])
        XCTAssertEqual(backend.stoppedURLs, [allowed.standardizedFileURL])
    }

    func testKnownContainerAccessBypassesSecurityScopeEvenWhenStartWouldFail() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        backend.denyEveryStart = true
        let container = temporaryURL("container")
        let child = container.appendingPathComponent("Library/catalog.sqlite")
        let store = makeStore(defaults, backend, roots: [container])

        let lease = try await store.acquire(url: child)

        XCTAssertEqual(lease.url, child.standardizedFileURL)
        XCTAssertTrue(backend.startedURLs.isEmpty)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testSymlinkEscapingContainerIsNotTreatedAsContainerOwned() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let fixture = temporaryURL("symlink-fixture")
        let container = fixture.appendingPathComponent("container", isDirectory: true)
        let external = fixture.appendingPathComponent("external", isDirectory: true)
        let link = container.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let escapedChild = link.appendingPathComponent("new.fit")

        await assertAccessThrows(try await makeStore(defaults, backend, roots: [container]).acquire(url: escapedChild)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(escapedChild.standardizedFileURL))
        }
        XCTAssertTrue(backend.startedURLs.isEmpty)
    }

    func testDanglingSymlinkCannotGiveUnscopedContainerAccess() async throws {
        let defaults = try isolatedDefaults(), backend = FakeBookmarkBackend()
        let fixture = temporaryURL("dangling-link")
        let container = fixture.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let link = container.appendingPathComponent("offline")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.appendingPathComponent("absent-share"))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        await assertAccessThrows(try await makeStore(defaults, backend, roots: [container]).acquire(url: link.appendingPathComponent("master.fit")))
        XCTAssertTrue(backend.startedURLs.isEmpty)
    }

    func testExternalBarePathIsNotAuthorizationAndFalseStartIsDenial() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let external = temporaryURL("external")
        let store = makeStore(defaults, backend)

        await assertAccessThrows(try await store.acquire(url: external)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(external.standardizedFileURL))
        }
        XCTAssertTrue(backend.startedURLs.isEmpty)

        backend.denyEveryStart = true
        await assertAccessThrows(try await store.select(external, key: "capture")) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .accessDenied(external.standardizedFileURL))
        }
        XCTAssertEqual(backend.startedURLs, [external.standardizedFileURL])
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testParentGrantCoversNewChildButNotSiblingPrefix() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let parent = temporaryURL("data")
        let child = parent.appendingPathComponent("night/new.fit")
        let siblingPrefix = parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + "base/new.fit")
        let key = "source:\(parent.standardizedFileURL.absoluteString)"
        let store = makeStore(defaults, backend)
        var selected: FileAccessLease? = try await store.select(parent, key: key)
        XCTAssertEqual(selected?.url, parent.standardizedFileURL)
        selected = nil

        var childLease: FileAccessLease? = try await store.acquire(url: child)
        XCTAssertEqual(childLease?.url, child.standardizedFileURL)
        childLease = nil
        await assertAccessThrows(try await store.acquire(url: siblingPrefix)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(siblingPrefix.standardizedFileURL))
        }
    }

    func testBrokenSpecificGrantFallsBackToValidParentGrant() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let parent = temporaryURL("parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let target = child.appendingPathComponent("file.fit")
        let store = makeStore(defaults, backend)
        var parentSelection: FileAccessLease? = try await store.select(parent, key: "source:\(parent.absoluteString)")
        var childSelection: FileAccessLease? = try await store.select(child, key: "source:\(child.absoluteString)")
        XCTAssertEqual(parentSelection?.url, parent)
        XCTAssertEqual(childSelection?.url, child)
        parentSelection = nil
        childSelection = nil
        let parentBookmark = try XCTUnwrap(backend.createdBookmarks.first)
        let childBookmark = try XCTUnwrap(backend.createdBookmarks.last)
        backend.deniedResolutions.insert(childBookmark)

        var operation: FileAccessLease? = try await store.acquire(url: target)

        XCTAssertEqual(operation?.url, target)
        XCTAssertEqual(backend.resolvedBookmarks.suffix(2), [childBookmark, parentBookmark])
        XCTAssertEqual(backend.startedURLs.last, parent)
        operation = nil
        XCTAssertEqual(backend.stoppedURLs.last, parent)
        XCTAssertEqual(backend.startedURLs.count, backend.stoppedURLs.count)
    }

    func testLeasesCrossExecutorsAndConcurrentCleanupBalancesEveryStart() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        assertSendable(backend as any BookmarkAccessing)
        let root = temporaryURL("concurrent")
        let store = makeStore(defaults, backend)

        let tasks = (0..<32).map { index in
            Task.detached { @Sendable in
                let lease = try? await store.select(root, key: "source:\(index)")
                await Task.yield()
                return lease?.url
            }
        }
        var returnedURLs: [URL] = []
        for task in tasks {
            if let url = await task.value {
                returnedURLs.append(url)
            }
        }

        XCTAssertEqual(returnedURLs, Array(repeating: root, count: 32))
        XCTAssertEqual(backend.startedURLs.count, 32)
        XCTAssertEqual(backend.stoppedURLs.count, 32)
        XCTAssertEqual(backend.startedURLs.sorted(by: { $0.absoluteString < $1.absoluteString }),
                       backend.stoppedURLs.sorted(by: { $0.absoluteString < $1.absoluteString }))
    }

    func testDirectPolicyPersistsSelectionsAndNeverUsesSecurityScope() async throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let selectedURL = temporaryURL("direct-selection")
        let bareURL = temporaryURL("direct-bare")
        var selected: FileAccessLease? = try await makeStore(defaults, backend, policy: .direct).select(selectedURL, key: "capture")
        XCTAssertEqual(selected?.url, selectedURL.standardizedFileURL)
        selected = nil

        let reopened = makeStore(defaults, backend, policy: .direct)
        await assertAccessEqual(try await reopened.acquire(key: "capture").url, selectedURL.standardizedFileURL)
        await assertAccessEqual(try await reopened.acquire(url: bareURL).url, bareURL.standardizedFileURL)
        XCTAssertTrue(backend.createdURLs.isEmpty)
        XCTAssertTrue(backend.startedURLs.isEmpty)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testMalformedRecordRefusesReplacementWithoutOverwriting() async throws {
        let defaults = try isolatedDefaults()
        let malformed = Data(#"{"version":1,"records":{"capture":{"displayPath":"/tmp/capture"}}}"#.utf8)
        defaults.set(malformed, forKey: AuthorizedLocations.defaultsKey)
        let backend = FakeBookmarkBackend()

        await assertAccessThrows(try await makeStore(defaults, backend).select(temporaryURL("replacement"), key: "capture")) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .malformedStorage)
        }
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), malformed)
        XCTAssertTrue(backend.createdURLs.isEmpty)
    }

    func testUnknownStorageVersionRefusesReplacementWithoutOverwriting() async throws {
        let defaults = try isolatedDefaults()
        let unknown = Data(#"{"version":99,"records":{}}"#.utf8)
        defaults.set(unknown, forKey: AuthorizedLocations.defaultsKey)
        let backend = FakeBookmarkBackend()

        await assertAccessThrows(try await makeStore(defaults, backend).select(temporaryURL("replacement"), key: "capture")) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .unsupportedStorageVersion(99))
        }
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), unknown)
        XCTAssertTrue(backend.createdURLs.isEmpty)
    }

    private func makeStore(_ defaults: UserDefaults,
                           _ backend: FakeBookmarkBackend,
                           policy: FileAccessPolicy = .sandboxed,
                           roots: [URL] = []) -> AuthorizedLocations {
        AuthorizedLocations(defaults: defaults, policy: policy, containerRoots: roots, backend: backend)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "AuthorizedLocationsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func temporaryURL(_ component: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthorizedLocationsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .standardizedFileURL
    }
}

private final class FakeBookmarkBackend: BookmarkAccessing, @unchecked Sendable {
    enum FakeError: Error {
        case createDenied
        case resolutionDenied
    }

    enum Event: Equatable {
        case create(URL)
        case resolve(Data)
        case start(URL)
        case stop(URL)
    }

    private let lock = NSLock()
    private var storedResolutions: [Data: BookmarkResolution] = [:]
    private var storedDeniedCreates: Set<URL> = []
    private var storedDeniedResolutions: Set<Data> = []
    private var storedDeniedStarts: Set<URL> = []
    private var storedDenyEveryStart = false
    private var storedEvents: [Event] = []
    private var storedCreatedBookmarks: [Data] = []
    private var storedPreparationThreads: [Bool] = []
    var preparationThreads: [Bool] { locked { storedPreparationThreads } }

    var resolutions: [Data: BookmarkResolution] {
        get { locked { storedResolutions } }
        set { locked { storedResolutions = newValue } }
    }

    var deniedCreates: Set<URL> {
        get { locked { storedDeniedCreates } }
        set { locked { storedDeniedCreates = newValue } }
    }

    var deniedResolutions: Set<Data> {
        get { locked { storedDeniedResolutions } }
        set { locked { storedDeniedResolutions = newValue } }
    }

    var deniedStarts: Set<URL> {
        get { locked { storedDeniedStarts } }
        set { locked { storedDeniedStarts = newValue } }
    }

    var denyEveryStart: Bool {
        get { locked { storedDenyEveryStart } }
        set { locked { storedDenyEveryStart = newValue } }
    }

    var events: [Event] {
        locked { storedEvents }
    }

    var createdBookmarks: [Data] {
        locked { storedCreatedBookmarks }
    }

    var createdURLs: [URL] {
        locked { storedEvents.compactMap { if case let .create(url) = $0 { return url }; return nil } }
    }

    var startedURLs: [URL] {
        locked { storedEvents.compactMap { if case let .start(url) = $0 { return url }; return nil } }
    }

    var stoppedURLs: [URL] {
        locked { storedEvents.compactMap { if case let .stop(url) = $0 { return url }; return nil } }
    }

    var resolvedBookmarks: [Data] {
        locked { storedEvents.compactMap { if case let .resolve(data) = $0 { return data }; return nil } }
    }

    func createBookmark(for url: URL) throws -> Data {
        try locked {
            storedPreparationThreads.append(Thread.isMainThread)
            let normalized = url.standardizedFileURL
            storedEvents.append(.create(normalized))
            guard !storedDeniedCreates.contains(normalized) else { throw FakeError.createDenied }
            let data = Data("bookmark-\(storedCreatedBookmarks.count)-\(normalized.absoluteString)".utf8)
            storedCreatedBookmarks.append(data)
            storedResolutions[data] = BookmarkResolution(url: normalized, isStale: false)
            return data
        }
    }

    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        try locked {
            storedPreparationThreads.append(Thread.isMainThread)
            storedEvents.append(.resolve(data))
            guard !storedDeniedResolutions.contains(data), let resolution = storedResolutions[data] else {
                throw FakeError.resolutionDenied
            }
            return resolution
        }
    }

    func startAccessing(_ url: URL) -> Bool {
        locked {
            storedPreparationThreads.append(Thread.isMainThread)
            let normalized = url.standardizedFileURL
            storedEvents.append(.start(normalized))
            return !storedDenyEveryStart && !storedDeniedStarts.contains(normalized)
        }
    }

    func stopAccessing(_ url: URL) {
        locked {
            storedEvents.append(.stop(url.standardizedFileURL))
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private func assertSendable<T: Sendable>(_ value: T) {}
