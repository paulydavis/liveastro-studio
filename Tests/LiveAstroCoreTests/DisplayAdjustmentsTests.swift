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

    func testLiveDefaultIsNeutralPlusDBE() {
        // liveDefault (fresh-install / Reset target) has DBE on; neutral (identity)
        // stays off. They differ only by backgroundExtraction.
        XCTAssertTrue(DisplayAdjustments.liveDefault.backgroundExtraction)
        XCTAssertFalse(DisplayAdjustments.neutral.backgroundExtraction)
        var expected = DisplayAdjustments.neutral
        expected.backgroundExtraction = true
        XCTAssertEqual(DisplayAdjustments.liveDefault, expected)
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

final class DisplayAdjustmentsDBEv3Tests: XCTestCase {
    func testNewFieldsHaveDefaultsAndRoundTrip() throws {
        var a = DisplayAdjustments.neutral
        XCTAssertEqual(a.bgScale, 3.0, accuracy: 1e-9)      // Task-1 validated default
        XCTAssertEqual(a.bgSmoothest, 0.5, accuracy: 1e-9)
        a.bgScale = 2.0; a.bgSmoothest = 0.2
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DisplayAdjustments.self, from: data)
        XCTAssertEqual(back.bgScale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(back.bgSmoothest, 0.2, accuracy: 1e-9)
    }

    func testDecodesOldSettingsWithoutBgFields() throws {
        // An old settings blob (no bgScale/bgSmoothest) must decode to defaults.
        let old = #"{"blackPoint":0,"midtoneStrength":0,"saturation":1,"backgroundExtraction":true,"backgroundDegree":2}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(old.utf8))
        XCTAssertEqual(a.bgScale, 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.bgSmoothest, 0.5, accuracy: 1e-9)
        XCTAssertTrue(a.backgroundExtraction)
    }
}

final class DisplayAdjustmentsNorthUpTests: XCTestCase {
    func testNorthUpDefaultsOffAndRoundTrips() throws {
        var a = DisplayAdjustments.neutral
        XCTAssertFalse(a.northUp)                             // default OFF (3b: toggle default off)
        a.northUp = true
        let back = try JSONDecoder().decode(DisplayAdjustments.self,
                                            from: JSONEncoder().encode(a))
        XCTAssertTrue(back.northUp)
    }

    func testDecodesOldSettingsWithoutNorthUpKey() throws {
        // A settings blob written before 3b must decode northUp as false.
        let old = #"{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5,"backgroundExtraction":true,"backgroundDegree":2,"bgScale":3.0,"bgSmoothest":0.5,"denoiseStrength":0.4}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(old.utf8))
        XCTAssertFalse(a.northUp)                             // absent -> off
        XCTAssertEqual(a.denoiseStrength, 0.4, accuracy: 1e-9)
    }
}

final class DisplayAdjustmentsDenoiseTests: XCTestCase {
    func testDenoiseDefaultsOffAndRoundTrips() throws {
        var a = DisplayAdjustments.neutral
        XCTAssertEqual(a.denoiseStrength, 0)                 // default OFF (spec §2.2)
        a.denoiseStrength = 0.6
        let back = try JSONDecoder().decode(DisplayAdjustments.self,
                                            from: JSONEncoder().encode(a))
        XCTAssertEqual(back.denoiseStrength, 0.6, accuracy: 1e-9)
    }

    func testDecodesOldSettingsWithoutDenoiseKey() throws {
        let old = #"{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5,"backgroundExtraction":true,"backgroundDegree":2,"bgScale":3.0,"bgSmoothest":0.5}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(old.utf8))
        XCTAssertEqual(a.denoiseStrength, 0)                 // absent -> off
        XCTAssertEqual(a.blackPoint, 0.1)
    }
}
