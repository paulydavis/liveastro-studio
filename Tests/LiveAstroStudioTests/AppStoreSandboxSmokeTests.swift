import Foundation
import XCTest
@testable import LiveAstroStudio

@MainActor
final class AppStoreSandboxSmokeTests: XCTestCase {
    func testAppStoreModelUsesSandboxBoundaryAndKeepsOBSReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppStoreSandboxSmoke.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.appstore",
                                                       containerRoot: root)
        let model = AppModel(userDefaults: defaults, configuration: configuration)

        XCTAssertTrue(model.isStorePreview, "the App Store bundle must use the sandbox access path")
        XCTAssertFalse(model.supportsExternalProcessor)
        XCTAssertFalse(model.supportsPublicStreamAutomation)
        XCTAssertFalse(model.supportsSceneAutomation)
        XCTAssertNotNil(model.obsConnectionCheck)
        XCTAssertNotNil(model.obsLocalRecording)
        XCTAssertTrue(configuration.relayRoot.path.hasPrefix(root.path))
        XCTAssertTrue(configuration.libraryRoot!.path.hasPrefix(root.path))
    }

    func testUnselectedMountedShareIsNotImplicitlyAdmitted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppStoreSandboxSmoke.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let locations = AuthorizedLocations(defaults: defaults, policy: .sandboxed,
                                            containerRoots: [root], backend: SmokeBookmarkBackend())

        do {
            _ = try await locations.acquire(key: "camera:seestar")
            XCTFail("a mounted but unselected camera share must not be used implicitly")
        } catch let error as AuthorizedLocationError {
            XCTAssertEqual(error, .missingSelection("camera:seestar"))
        }
    }

    func testStaleBookmarkIsRenewedAndDeniedAccessDoesNotEraseSelection() async throws {
        let suite = "AppStoreSandboxSmoke.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = SmokeBookmarkBackend()
        let locations = AuthorizedLocations(defaults: defaults, policy: .sandboxed,
                                            containerRoots: [], backend: backend)
        let original = URL(fileURLWithPath: "/tmp/app-store-camera-old")
        let moved = URL(fileURLWithPath: "/tmp/app-store-camera-new")
        _ = try await locations.select(original, key: "camera:seestar")
        backend.relocation = moved
        let renewed = try await locations.acquire(key: "camera:seestar")
        XCTAssertEqual(renewed.url.standardizedFileURL, moved.standardizedFileURL)
        backend.denied = true
        do { _ = try await locations.acquire(key: "camera:seestar"); XCTFail("denial must surface") }
        catch let error as AuthorizedLocationError { XCTAssertEqual(error, .accessDenied(moved)) }
        XCTAssertEqual(locations.displayURL(key: "camera:seestar")?.path,
                       moved.path)
    }
}

private final class SmokeBookmarkBackend: BookmarkAccessing, @unchecked Sendable {
    var relocation: URL?
    var denied = false
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        let old = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
        return BookmarkResolution(url: relocation ?? old, isStale: relocation != nil)
    }
    func startAccessing(_ url: URL) -> Bool { !denied }
    func stopAccessing(_ url: URL) {}
}
