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
}
