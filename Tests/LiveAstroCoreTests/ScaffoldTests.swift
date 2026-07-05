import XCTest
@testable import LiveAstroCore

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(LiveAstroCore.version, "0.1.0")
    }
}
