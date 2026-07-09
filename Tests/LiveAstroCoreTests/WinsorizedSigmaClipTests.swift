import XCTest
@testable import LiveAstroCore

final class WinsorizedSigmaClipTests: XCTestCase {
    // single-pixel 1x1 mono frame
    func px(_ v: Float) -> AstroImage {
        AstroImage(width: 1, height: 1, channels: 1, pixels: [v], sourceIsLinear: true)
    }
    let m: [Float] = [1]

    func testWarmUpPassesRaw() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        // first frame is a wild outlier; within warm-up it must pass through untouched
        XCTAssertEqual(r.apply(px(0.9), mask: m).pixels[0], 0.9, accuracy: 1e-6)
    }

    func testOutlierClampedAfterWarmUp() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        // 8 warm-up frames with small spread around ~0.05 → σ ≈ 0.008
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // 9th frame is a bright streak; count == 8 ≥ warmUp → clamp to ≈ mean + 3σ (well below 0.9)
        let out = r.apply(px(0.9), mask: m).pixels[0]
        XCTAssertLessThan(out, 0.2)
        XCTAssertGreaterThan(out, 0.05)   // clamped near the mean, not zeroed
    }

    func testInDistributionValueUnchanged() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // a value within ±3σ of the mean must pass through unclamped
        let inD: Float = 0.056
        XCTAssertEqual(r.apply(px(inD), mask: m).pixels[0], inD, accuracy: 1e-5)
    }

    func testUpdateWithClampedKeepsSigmaBounded() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // repeated bright outliers: each stays clamped near the mean because stats update
        // with the CLAMPED value (σ never grows to admit 0.9)
        var last: Float = 0
        for _ in 0..<5 { last = r.apply(px(0.9), mask: m).pixels[0] }
        XCTAssertLessThan(last, 0.2)
    }

    func testResetRestartsWarmUp() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05] { _ = r.apply(px(v), mask: m) }
        r.reset()
        // after reset, an outlier is within warm-up again → passes raw
        XCTAssertEqual(r.apply(px(0.9), mask: m).pixels[0], 0.9, accuracy: 1e-6)
    }

    func testMaskedPixelUntouched() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 1)
        // 2-pixel frame; pixel 1 masked-out (mask 0) must pass through with no state/clamp
        _ = r.apply(AstroImage(width: 2, height: 1, channels: 1, pixels: [0.05, 0.9], sourceIsLinear: true), mask: [1, 0])
        let out = r.apply(AstroImage(width: 2, height: 1, channels: 1, pixels: [0.05, 0.9], sourceIsLinear: true), mask: [1, 0])
        XCTAssertEqual(out.pixels[1], 0.9, accuracy: 1e-6)   // never clamped — always out-of-bounds
    }
}
