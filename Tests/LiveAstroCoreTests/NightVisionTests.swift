import XCTest
@testable import LiveAstroCore

final class NightVisionTests: XCTestCase {
    func testDefaultLevelIs65() {
        XCTAssertEqual(NightVision().level, 65)
        XCTAssertEqual(NightVision.defaultLevel, 65)
    }

    func testClampBelowRangePinsToMin() {
        XCTAssertEqual(NightVision(level: 0).level, 1)
        XCTAssertEqual(NightVision(level: -50).level, 1)
        XCTAssertEqual(NightVision.clamp(-1), 1)
    }

    func testClampAboveRangePinsToMax() {
        XCTAssertEqual(NightVision(level: 101).level, 100)
        XCTAssertEqual(NightVision(level: 5000).level, 100)
        XCTAssertEqual(NightVision.clamp(200), 100)
    }

    func testInRangeLevelsPreserved() {
        for l in [1, 25, 50, 65, 99, 100] {
            XCTAssertEqual(NightVision(level: l).level, l)
        }
    }

    func testRedMaxMapping() {
        XCTAssertEqual(NightVision(level: 100).redMax, 1.0, accuracy: 1e-6)
        XCTAssertEqual(NightVision(level: 50).redMax, 0.5, accuracy: 1e-6)
        XCTAssertEqual(NightVision(level: 1).redMax, 0.01, accuracy: 1e-6)
    }

    // redMax feeds a gamma table ceiling: it must never leave the [0, 1] the API expects,
    // and must be strictly positive so the screen is never driven fully black.
    func testRedMaxAlwaysWithinValidGammaRange() {
        for l in [-10, 0, 1, 33, 65, 100, 250] {
            let v = NightVision(level: l).redMax
            XCTAssertGreaterThan(v, 0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }
}
