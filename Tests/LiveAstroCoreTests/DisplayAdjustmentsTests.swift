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
}
