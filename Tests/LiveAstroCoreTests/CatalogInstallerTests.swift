import XCTest
import CryptoKit
@testable import LiveAstroCore

final class CatalogInstallerTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        CatalogInstaller.cacheDirectoryOverride = tmpRoot.appendingPathComponent("cache")
        CatalogInstaller.expectedSHA256 = ""
    }
    override func tearDownWithError() throws {
        CatalogInstaller.cacheDirectoryOverride = nil
        CatalogInstaller.expectedSHA256 = ""
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// A small valid catalog encoded to bytes + written to a file:// source.
    private func fixture() throws -> (url: URL, data: Data) {
        let stars = (0..<20).map { CatalogStar(ra: Float($0) * 3, dec: Float($0) - 5, mag: 6.0) }
        let data = StarCatalog.encode(stars)
        let url = tmpRoot.appendingPathComponent("src.bin")
        try data.write(to: url)
        return (url, data)
    }
    private func sha256hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testDownloadsFromFileURLAndInstalls() async throws {
        let (src, data) = try fixture()
        CatalogInstaller.expectedSHA256 = sha256hex(data)
        XCTAssertFalse(CatalogInstaller.isInstalled())
        try await CatalogInstaller.download(from: src, progress: { _ in })
        XCTAssertTrue(CatalogInstaller.isInstalled())
        XCTAssertEqual(try Data(contentsOf: CatalogInstaller.cacheURL()), data, "cached bytes == source")
    }

    func testChecksumMismatchThrowsAndLeavesCacheClean() async throws {
        let (src, _) = try fixture()
        CatalogInstaller.expectedSHA256 = String(repeating: "0", count: 64)   // wrong
        do {
            try await CatalogInstaller.download(from: src, progress: { _ in })
            XCTFail("expected checksumMismatch")
        } catch CatalogInstaller.InstallError.checksumMismatch {
            // expected
        }
        XCTAssertFalse(CatalogInstaller.isInstalled(), "cache must stay clean on checksum failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogInstaller.cacheURL().path))
    }

    func testCorruptPayloadRejectedAndCacheClean() async throws {
        // Not a valid LASC blob (bad magic) — checksum disabled so it reaches the parse check.
        let bad = Data(repeating: 0x42, count: 4096)
        let src = tmpRoot.appendingPathComponent("bad.bin")
        try bad.write(to: src)
        CatalogInstaller.expectedSHA256 = ""
        do {
            try await CatalogInstaller.download(from: src, progress: { _ in })
            XCTFail("expected invalidCatalog")
        } catch CatalogInstaller.InstallError.invalidCatalog {
            // expected
        }
        XCTAssertFalse(CatalogInstaller.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogInstaller.cacheURL().path))
    }

    func testProgressReachesOne() async throws {
        let (src, data) = try fixture()
        CatalogInstaller.expectedSHA256 = sha256hex(data)
        let lock = NSLock(); var last = 0.0
        try await CatalogInstaller.download(from: src, progress: { p in lock.withLock { last = p } })
        XCTAssertEqual(lock.withLock { last }, 1.0, accuracy: 1e-9)
    }
}
