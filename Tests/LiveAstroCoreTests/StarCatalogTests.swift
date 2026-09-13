import XCTest
@testable import LiveAstroCore

final class StarCatalogTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let stars = [CatalogStar(ra: 10.5, dec: -20.25, mag: 6.1),
                     CatalogStar(ra: 200.0, dec: 45.5, mag: 7.9),
                     CatalogStar(ra: 359.9, dec: 0.0, mag: 4.2)]
        let data = StarCatalog.encode(stars)
        let cat = try StarCatalog(data: data)
        XCTAssertEqual(cat.count, 3)
        // stored sorted by ascending dec
        XCTAssertEqual(cat.stars, stars.sorted { $0.dec < $1.dec })
    }

    func testBadMagicThrows() {
        var data = StarCatalog.encode([CatalogStar(ra: 1, dec: 2, mag: 3)])
        data[0] = 0x00   // corrupt magic
        XCTAssertThrowsError(try StarCatalog(data: data)) { error in
            XCTAssertEqual(error as? StarCatalog.CatalogError, .badMagic)
        }
    }

    func testTruncatedThrows() {
        let data = StarCatalog.encode([CatalogStar(ra: 1, dec: 2, mag: 3)])
        XCTAssertThrowsError(try StarCatalog(data: data.prefix(14))) { error in
            XCTAssertEqual(error as? StarCatalog.CatalogError, .truncated)
        }
    }

    private func cat(_ s: [CatalogStar]) -> StarCatalog { try! StarCatalog(data: StarCatalog.encode(s)) }

    func testQueryReturnsWithinRadiusExcludesOutside() {
        let c = cat([CatalogStar(ra: 100, dec: 10, mag: 5),    // center
                     CatalogStar(ra: 100.5, dec: 10, mag: 6),  // ~0.49° away → inside 1°
                     CatalogStar(ra: 105, dec: 10, mag: 7)])   // ~4.9° away → outside 1°
        let got = c.stars(nearRA: 100, dec: 10, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }

    func testQueryHandlesRA0Seam() {
        // stars straddling the 0h seam must both be found (dot-product, not RA subtraction)
        let c = cat([CatalogStar(ra: 359.7, dec: 0, mag: 5),
                     CatalogStar(ra: 0.3, dec: 0, mag: 6),
                     CatalogStar(ra: 180, dec: 0, mag: 7)])   // opposite side → excluded
        let got = c.stars(nearRA: 0.0, dec: 0.0, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }

    func testQueryNearPole() {
        // near the pole RA converges; two stars at dec 89.5 with very different RA are both close
        let c = cat([CatalogStar(ra: 0, dec: 89.6, mag: 5),
                     CatalogStar(ra: 180, dec: 89.6, mag: 6),  // ~0.8° away over the pole
                     CatalogStar(ra: 90, dec: 80, mag: 7)])    // ~9.6° away → excluded
        let got = c.stars(nearRA: 90, dec: 90, radiusDegrees: 1.0)
        XCTAssertEqual(Set(got.map { $0.mag }), [5, 6])
    }

    /// Fail-closed contract: installed() must NEVER return a non-nil but EMPTY catalog. Either nil
    /// (not downloaded / malformed / empty) or a real catalog — so solver code that does
    /// `if let cat = installed()` cleanly disables plate-solve on no-data. No cached file → nil; an
    /// empty (count-0) cached file → still nil.
    func testInstalledIsNilWhenAbsentOrEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        CatalogInstaller.cacheDirectoryOverride = tmp
        defer { CatalogInstaller.cacheDirectoryOverride = nil }
        XCTAssertNil(StarCatalog.installed(), "no cache → installed() nil")
        // stage an EMPTY catalog (valid LASC header, count 0) → still nil, never a non-nil empty one
        try FileManager.default.createDirectory(at: CatalogInstaller.cacheURL().deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try StarCatalog.encode([]).write(to: CatalogInstaller.cacheURL())
        XCTAssertNil(StarCatalog.installed(), "empty cached catalog → installed() nil")
    }

    /// A catalog staged into the cache loads via installed() and is queryable.
    func testInstalledLoadsAndQueriesStagedCatalog() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        CatalogInstaller.cacheDirectoryOverride = tmp
        defer { CatalogInstaller.cacheDirectoryOverride = nil }
        let stars = [CatalogStar(ra: 305.0, dec: 40.0, mag: 6), CatalogStar(ra: 305.4, dec: 40.3, mag: 7),
                     CatalogStar(ra: 120.0, dec: -10.0, mag: 5)]
        try FileManager.default.createDirectory(at: CatalogInstaller.cacheURL().deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try StarCatalog.encode(stars).write(to: CatalogInstaller.cacheURL())
        let cat = try XCTUnwrap(StarCatalog.installed())
        XCTAssertEqual(cat.count, 3)
        XCTAssertFalse(cat.stars(nearRA: 305.0, dec: 40.0, radiusDegrees: 3.0).isEmpty)
    }
}
