import Foundation
import XCTest
@testable import LiveAstroStudio

@MainActor
final class AuthorizedLocationsTests: XCTestCase {
    func testFreshStoreRestoresPersistedGrant() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let input = temporaryURL("capture")
        var selected: FileAccessLease? = try makeStore(defaults, backend).select(input, key: "capture")
        XCTAssertEqual(selected?.url, input.standardizedFileURL)
        selected = nil

        let reopened = makeStore(defaults, backend)
        var restored: FileAccessLease? = try reopened.acquire(key: "capture")
        XCTAssertEqual(restored?.url, input.standardizedFileURL)
        restored = nil

        XCTAssertEqual(backend.startedURLs, [input.standardizedFileURL, input.standardizedFileURL])
        XCTAssertEqual(backend.stoppedURLs, [input.standardizedFileURL, input.standardizedFileURL])
    }

    func testStaleGrantRenewsAfterAccessAndUsesMovedURL() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let original = temporaryURL("original")
        let moved = temporaryURL("moved")
        var selected: FileAccessLease? = try makeStore(defaults, backend).select(original, key: "capture")
        XCTAssertEqual(selected?.url, original.standardizedFileURL)
        selected = nil
        let oldBookmark = try XCTUnwrap(backend.createdBookmarks.first)
        backend.resolutions[oldBookmark] = BookmarkResolution(url: moved, isStale: true)

        var restored: FileAccessLease? = try makeStore(defaults, backend).acquire(key: "capture")
        XCTAssertEqual(restored?.url, moved.standardizedFileURL)
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "capture"), moved.standardizedFileURL)
        XCTAssertEqual(backend.createdURLs, [original.standardizedFileURL, moved.standardizedFileURL])
        XCTAssertEqual(backend.events.suffix(2), [.start(moved.standardizedFileURL), .create(moved.standardizedFileURL)])
        restored = nil
        XCTAssertEqual(backend.stoppedURLs.last, moved.standardizedFileURL)
    }

    func testDeniedResolutionPreservesPersistedRecordAndDisplayPath() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let input = temporaryURL("denied")
        var selected: FileAccessLease? = try makeStore(defaults, backend).select(input, key: "capture")
        XCTAssertEqual(selected?.url, input.standardizedFileURL)
        selected = nil
        let bookmark = try XCTUnwrap(backend.createdBookmarks.first)
        let storedBefore = try XCTUnwrap(defaults.data(forKey: AuthorizedLocations.defaultsKey))
        backend.deniedResolutions.insert(bookmark)

        XCTAssertThrowsError(try makeStore(defaults, backend).acquire(key: "capture"))
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), storedBefore)
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "capture"), input.standardizedFileURL)
    }

    func testFailedReplacementPreservesOldGrantAndDoesNotStopHeldLease() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let oldURL = temporaryURL("old")
        let newURL = temporaryURL("new")
        var held: FileAccessLease? = try makeStore(defaults, backend).select(oldURL, key: "output")
        backend.deniedCreates.insert(newURL.standardizedFileURL)

        XCTAssertThrowsError(try makeStore(defaults, backend).select(newURL, key: "output"))
        XCTAssertEqual(makeStore(defaults, backend).displayURL(key: "output"), oldURL.standardizedFileURL)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
        XCTAssertEqual(held?.url, oldURL.standardizedFileURL)

        held = nil
        XCTAssertEqual(backend.stoppedURLs, [oldURL.standardizedFileURL])
    }

    func testReplacingSelectionLeavesBothOperationLeasesIndependentlyOwned() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let firstURL = temporaryURL("first")
        let secondURL = temporaryURL("second")
        let store = makeStore(defaults, backend)
        var first: FileAccessLease? = try store.select(firstURL, key: "capture")
        var second: FileAccessLease? = try store.select(secondURL, key: "capture")

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

    func testOnlySuccessfulStartsAreBalancedByStops() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let allowed = temporaryURL("allowed")
        let denied = temporaryURL("denied")
        var lease: FileAccessLease? = try makeStore(defaults, backend).select(allowed, key: "capture")
        XCTAssertEqual(lease?.url, allowed.standardizedFileURL)
        backend.deniedStarts.insert(denied.standardizedFileURL)

        XCTAssertThrowsError(try makeStore(defaults, backend).select(denied, key: "output"))
        XCTAssertEqual(backend.stoppedURLs, [])
        lease = nil
        XCTAssertEqual(backend.startedURLs, [allowed.standardizedFileURL, denied.standardizedFileURL])
        XCTAssertEqual(backend.stoppedURLs, [allowed.standardizedFileURL])
    }

    func testKnownContainerAccessBypassesSecurityScopeEvenWhenStartWouldFail() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        backend.denyEveryStart = true
        let container = temporaryURL("container")
        let child = container.appendingPathComponent("Library/catalog.sqlite")
        let store = makeStore(defaults, backend, roots: [container])

        let lease = try store.acquire(url: child)

        XCTAssertEqual(lease.url, child.standardizedFileURL)
        XCTAssertTrue(backend.startedURLs.isEmpty)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testSymlinkEscapingContainerIsNotTreatedAsContainerOwned() throws {
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

        XCTAssertThrowsError(try makeStore(defaults, backend, roots: [container]).acquire(url: escapedChild)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(escapedChild.standardizedFileURL))
        }
        XCTAssertTrue(backend.startedURLs.isEmpty)
    }

    func testExternalBarePathIsNotAuthorizationAndFalseStartIsDenial() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let external = temporaryURL("external")
        let store = makeStore(defaults, backend)

        XCTAssertThrowsError(try store.acquire(url: external)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(external.standardizedFileURL))
        }
        XCTAssertTrue(backend.startedURLs.isEmpty)

        backend.denyEveryStart = true
        XCTAssertThrowsError(try store.select(external, key: "capture")) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .accessDenied(external.standardizedFileURL))
        }
        XCTAssertEqual(backend.startedURLs, [external.standardizedFileURL])
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testParentGrantCoversNewChildButNotSiblingPrefix() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let parent = temporaryURL("data")
        let child = parent.appendingPathComponent("night/new.fit")
        let siblingPrefix = parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + "base/new.fit")
        let key = "source:\(parent.standardizedFileURL.absoluteString)"
        let store = makeStore(defaults, backend)
        var selected: FileAccessLease? = try store.select(parent, key: key)
        XCTAssertEqual(selected?.url, parent.standardizedFileURL)
        selected = nil

        var childLease: FileAccessLease? = try store.acquire(url: child)
        XCTAssertEqual(childLease?.url, child.standardizedFileURL)
        childLease = nil
        XCTAssertThrowsError(try store.acquire(url: siblingPrefix)) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .notAuthorized(siblingPrefix.standardizedFileURL))
        }
    }

    func testDirectPolicyPersistsSelectionsAndNeverUsesSecurityScope() throws {
        let defaults = try isolatedDefaults()
        let backend = FakeBookmarkBackend()
        let selectedURL = temporaryURL("direct-selection")
        let bareURL = temporaryURL("direct-bare")
        var selected: FileAccessLease? = try makeStore(defaults, backend, policy: .direct).select(selectedURL, key: "capture")
        XCTAssertEqual(selected?.url, selectedURL.standardizedFileURL)
        selected = nil

        let reopened = makeStore(defaults, backend, policy: .direct)
        XCTAssertEqual(try reopened.acquire(key: "capture").url, selectedURL.standardizedFileURL)
        XCTAssertEqual(try reopened.acquire(url: bareURL).url, bareURL.standardizedFileURL)
        XCTAssertTrue(backend.createdURLs.isEmpty)
        XCTAssertTrue(backend.startedURLs.isEmpty)
        XCTAssertTrue(backend.stoppedURLs.isEmpty)
    }

    func testMalformedRecordRefusesReplacementWithoutOverwriting() throws {
        let defaults = try isolatedDefaults()
        let malformed = Data(#"{"version":1,"records":{"capture":{"displayPath":"/tmp/capture"}}}"#.utf8)
        defaults.set(malformed, forKey: AuthorizedLocations.defaultsKey)
        let backend = FakeBookmarkBackend()

        XCTAssertThrowsError(try makeStore(defaults, backend).select(temporaryURL("replacement"), key: "capture")) { error in
            XCTAssertEqual(error as? AuthorizedLocationError, .malformedStorage)
        }
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), malformed)
        XCTAssertTrue(backend.createdURLs.isEmpty)
    }

    func testUnknownStorageVersionRefusesReplacementWithoutOverwriting() throws {
        let defaults = try isolatedDefaults()
        let unknown = Data(#"{"version":99,"records":{}}"#.utf8)
        defaults.set(unknown, forKey: AuthorizedLocations.defaultsKey)
        let backend = FakeBookmarkBackend()

        XCTAssertThrowsError(try makeStore(defaults, backend).select(temporaryURL("replacement"), key: "capture")) { error in
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

private final class FakeBookmarkBackend: BookmarkAccessing {
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

    var resolutions: [Data: BookmarkResolution] = [:]
    var deniedCreates: Set<URL> = []
    var deniedResolutions: Set<Data> = []
    var deniedStarts: Set<URL> = []
    var denyEveryStart = false
    private(set) var events: [Event] = []
    private(set) var createdBookmarks: [Data] = []

    var createdURLs: [URL] {
        events.compactMap { if case let .create(url) = $0 { return url }; return nil }
    }

    var startedURLs: [URL] {
        events.compactMap { if case let .start(url) = $0 { return url }; return nil }
    }

    var stoppedURLs: [URL] {
        events.compactMap { if case let .stop(url) = $0 { return url }; return nil }
    }

    func createBookmark(for url: URL) throws -> Data {
        let normalized = url.standardizedFileURL
        events.append(.create(normalized))
        guard !deniedCreates.contains(normalized) else { throw FakeError.createDenied }
        let data = Data("bookmark-\(createdBookmarks.count)-\(normalized.absoluteString)".utf8)
        createdBookmarks.append(data)
        resolutions[data] = BookmarkResolution(url: normalized, isStale: false)
        return data
    }

    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        events.append(.resolve(data))
        guard !deniedResolutions.contains(data), let resolution = resolutions[data] else {
            throw FakeError.resolutionDenied
        }
        return resolution
    }

    func startAccessing(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        events.append(.start(normalized))
        return !denyEveryStart && !deniedStarts.contains(normalized)
    }

    func stopAccessing(_ url: URL) {
        events.append(.stop(url.standardizedFileURL))
    }
}
