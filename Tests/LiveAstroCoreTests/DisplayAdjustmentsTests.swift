import XCTest
@testable import LiveAstroCore

final class DisplayAdjustmentsTests: XCTestCase {
    func testNeutralDefaults() {
        let n = DisplayAdjustments.neutral
        XCTAssertEqual(n.blackPoint, 0)
        XCTAssertEqual(n.midtoneStrength, 0)
        XCTAssertEqual(n.saturation, 1)
        XCTAssertEqual(DisplayAdjustments(), n)   // default init == neutral
    }

    func testCodableRoundTrip() throws {
        let a = DisplayAdjustments(blackPoint: 0.1, midtoneStrength: -0.4, saturation: 1.6)
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(DisplayAdjustments.self, from: data)
        XCTAssertEqual(a, b)
    }

    func testInitDoesNotClamp() {
        // Out-of-range persists as-is; clamping happens on apply (AutoStretch), not here.
        let a = DisplayAdjustments(blackPoint: 5, midtoneStrength: -9, saturation: 42)
        XCTAssertEqual(a.blackPoint, 5)
        XCTAssertEqual(a.midtoneStrength, -9)
        XCTAssertEqual(a.saturation, 42)
    }

    func testDBEDefaultsOffPlanar() {
        let n = DisplayAdjustments.neutral
        XCTAssertFalse(n.backgroundExtraction)
        XCTAssertEqual(n.backgroundDegree, 1)
        XCTAssertEqual(DisplayAdjustments(), n)
    }

    func testDBERoundTrip() throws {
        let a = DisplayAdjustments(blackPoint: 0.05, midtoneStrength: 0.2, saturation: 1.3,
                                   backgroundExtraction: true, backgroundDegree: 2)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(DisplayAdjustments.self, from: data), a)
    }

    func testOldBlobWithoutDBEKeysDecodesDefaults() throws {
        // JSON written before the DBE fields existed (only the original three keys).
        let json = #"{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(json.utf8))
        XCTAssertEqual(a.blackPoint, 0.1)
        XCTAssertFalse(a.backgroundExtraction)   // absent → default
        XCTAssertEqual(a.backgroundDegree, 1)    // absent → default
    }
}
