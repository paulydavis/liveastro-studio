import XCTest
@testable import LiveAstroCore

final class CalibrationMatcherTests: XCTestCase {

    private func master(_ kind: MasterKind, camera: String = "ASI2600", gain: Double? = 100,
                        exp: Double?, temp: Double? = -10, binning: Int? = 1) -> MasterFrame {
        MasterFrame(id: UUID(), kind: kind, camera: camera, gain: gain, exposureSeconds: exp,
                    setTempC: temp, binning: binning, width: 4, height: 4, channels: 1,
                    frameCount: 10, createdAt: Date(), fileName: "m.fit", sourcePath: nil)
    }

    private func light(camera: String? = "ASI2600", gain: Double? = 100,
                       exp: Double? = 180, temp: Double? = -10, binning: Int? = 1) -> SourceMetadata {
        var m = SourceMetadata()
        m.instrument = camera; m.gain = gain; m.exposureSeconds = exp
        m.setTempC = temp; m.binning = binning
        return m
    }

    func testExactExposureAndTempMatch() {
        let d = master(.dark, exp: 180)
        let r = CalibrationMatcher.match(light: light(), library: [d])
        XCTAssertEqual(r.dark, .exact(d))
    }

    func testTempWithinToleranceStillExact() {
        let d = master(.dark, exp: 180, temp: -10)
        let r = CalibrationMatcher.match(light: light(temp: -11.5), library: [d])   // 1.5°C ≤ 2
        XCTAssertEqual(r.dark, .exact(d))
    }

    func testTempOutsideToleranceIsNoMatch() {
        let d = master(.dark, exp: 180, temp: -10)
        let r = CalibrationMatcher.match(light: light(temp: -14), library: [d])     // 4°C > 2
        if case .none = r.dark {} else { XCTFail("expected no match, got \(r.dark)") }
    }

    func testUncooledMatchesIgnoringTempWithWarning() {
        let d = master(.dark, exp: 180, temp: -10)
        let r = CalibrationMatcher.match(light: light(temp: nil), library: [d])
        XCTAssertEqual(r.dark, .exact(d))
        XCTAssertTrue(r.warnings.contains { $0.lowercased().contains("temperature") })
    }

    func testScaleFallbackUsesNearestDarkPlusBias() {
        let d120 = master(.dark, exp: 120)
        let bias = master(.bias, exp: nil)
        let r = CalibrationMatcher.match(light: light(exp: 180), library: [d120, bias])
        if case let .scaled(base, b, factor) = r.dark {
            XCTAssertEqual(base, d120); XCTAssertEqual(b, bias)
            XCTAssertEqual(factor, 1.5, accuracy: 1e-9)
        } else { XCTFail("expected scaled, got \(r.dark)") }
    }

    func testScaleDisabledFallsThroughToNone() {
        let d120 = master(.dark, exp: 120); let bias = master(.bias, exp: nil)
        let r = CalibrationMatcher.match(light: light(exp: 180), library: [d120, bias],
                                         options: .init(scaleEnabled: false))
        if case .none = r.dark {} else { XCTFail("expected none, got \(r.dark)") }
    }

    func testNoBiasCannotScale() {
        let d120 = master(.dark, exp: 120)
        let r = CalibrationMatcher.match(light: light(exp: 180), library: [d120])
        if case .none = r.dark {} else { XCTFail("expected none, got \(r.dark)") }
    }

    func testBiasIsReturnedAlongsideDark() {
        let d = master(.dark, exp: 180); let bias = master(.bias, exp: nil)
        let r = CalibrationMatcher.match(light: light(), library: [d, bias])
        XCTAssertEqual(r.bias, bias)
    }

    func testCameraMismatchNoDark() {
        let d = master(.dark, camera: "ASI2600", exp: 180)
        let r = CalibrationMatcher.match(light: light(camera: "Seestar"), library: [d])
        if case .none = r.dark {} else { XCTFail("expected none, got \(r.dark)") }
    }

    /// Uncooled cameras (Seestar etc.) report CCD-TEMP (actual, uncontrolled) but no SET-TEMP.
    /// CCD-TEMP is telemetry, not a dark-library setpoint, so a temperature difference must NOT
    /// reject the dark. Only SET-TEMP is a controlled setpoint that gates the ±tolerance rule.
    func testUncooledCcdTempIsNotUsedAsSetpoint() {
        var l = SourceMetadata()
        l.instrument = "Seestar"; l.gain = 100; l.exposureSeconds = 10
        l.ccdTempC = 30; l.setTempC = nil; l.binning = 1
        // A dark that carries a differing set-point (e.g. an older entry, or a cooled sibling):
        let d = master(.dark, camera: "Seestar", exp: 10, temp: 35, binning: 1)
        let r = CalibrationMatcher.match(light: l, library: [d])
        XCTAssertEqual(r.dark, .exact(d),
                       "uncooled light (CCD-TEMP only) must not be rejected on temperature")
    }

    /// When the lights have no recorded exposure and multiple darks match, the matcher must NOT
    /// silently pick the first (insertion order) — that's an arbitrary, likely-wrong calibration.
    func testNilExposureWithMultipleDarksIsAmbiguousNoMatch() {
        let d30 = master(.dark, exp: 30); let d300 = master(.dark, exp: 300)
        var l = light(); l.exposureSeconds = nil
        let r = CalibrationMatcher.match(light: l, library: [d30, d300])
        if case .none = r.dark {} else {
            XCTFail("nil exposure + 2 darks must be ambiguous no-match, got \(r.dark)")
        }
    }

    /// With exactly one matching dark, an unknown light exposure is unambiguous → still usable.
    func testNilExposureWithSingleDarkStillMatches() {
        let d = master(.dark, exp: 30)
        var l = light(); l.exposureSeconds = nil
        let r = CalibrationMatcher.match(light: l, library: [d])
        XCTAssertEqual(r.dark, .exact(d))
    }
}
