import XCTest
@testable import LiveAstroCore

final class DarkScalerTests: XCTestCase {
    private func img(_ pixels: [Float]) -> AstroImage {
        AstroImage(width: pixels.count, height: 1, channels: 1, pixels: pixels, sourceIsLinear: true)
    }

    func testFactorOneIsIdentity() {
        let dark = img([0.10, 0.30]); let bias = img([0.05, 0.05])
        let out = DarkScaler.scale(dark: dark, bias: bias, factor: 1.0)
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.pixels[0], 0.10, accuracy: 1e-6)
        XCTAssertEqual(out!.pixels[1], 0.30, accuracy: 1e-6)
    }

    func testScalesThermalNotBias() {
        // bias=0.05; thermal at dark exposure = dark-bias. Doubling exposure doubles thermal.
        let dark = img([0.10, 0.30]); let bias = img([0.05, 0.05])
        let out = DarkScaler.scale(dark: dark, bias: bias, factor: 2.0)!
        // p0: 0.05 + (0.10-0.05)*2 = 0.15 ; p1: 0.05 + (0.30-0.05)*2 = 0.55
        XCTAssertEqual(out.pixels[0], 0.15, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[1], 0.55, accuracy: 1e-6)
    }

    func testHalfExposureShrinksThermal() {
        let dark = img([0.05, 0.45]); let bias = img([0.05, 0.05])
        let out = DarkScaler.scale(dark: dark, bias: bias, factor: 0.5)!
        // p0: 0.05 + 0*0.5 = 0.05 ; p1: 0.05 + 0.40*0.5 = 0.25
        XCTAssertEqual(out.pixels[0], 0.05, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[1], 0.25, accuracy: 1e-6)
    }

    func testClampsNegativeToZero() {
        // dark below bias (noise) with a shrink factor could go negative → clamp to 0.
        let dark = img([0.02]); let bias = img([0.05])
        let out = DarkScaler.scale(dark: dark, bias: bias, factor: 3.0)!
        // 0.05 + (0.02-0.05)*3 = 0.05 - 0.09 = -0.04 → 0
        XCTAssertEqual(out.pixels[0], 0.0, accuracy: 1e-7)
    }

    func testNilOnDimensionMismatch() {
        XCTAssertNil(DarkScaler.scale(dark: img([0.1, 0.2]), bias: img([0.1]), factor: 1.0))
    }

    /// A corrupt exposure yields a non-finite factor (Float(1e100)=+Inf); scaling must refuse rather
    /// than emit a non-finite dark that would black out every calibrated frame.
    func testRejectsNonFiniteOrNonPositiveFactor() {
        let dark = img([0.10, 0.30]); let bias = img([0.05, 0.05])
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: .infinity))
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: .nan))
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: 0))
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: -1))
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: 1e100))   // Float overflow → +Inf
        let ok = DarkScaler.scale(dark: dark, bias: bias, factor: 1.5)
        XCTAssertNotNil(ok)
        XCTAssertTrue(ok!.pixels.allSatisfy { $0.isFinite }, "valid results are always finite")
    }

    /// A tiny positive+finite Double factor (e.g. 180 / 1e100 ≈ 1.8e-98) underflows Float to 0.0,
    /// which would make the "scaled dark" equal the bias. It must be rejected, not accepted.
    func testRejectsFactorThatUnderflowsFloatToZero() {
        let dark = img([0.10, 0.30]); let bias = img([0.05, 0.05])
        XCTAssertNil(DarkScaler.scale(dark: dark, bias: bias, factor: 1.8e-98))
    }
}
