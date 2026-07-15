// Tests/LiveAstroCoreTests/GradientLevelerTests.swift
import XCTest
@testable import LiveAstroCore

final class GradientLevelerTests: XCTestCase {
    typealias Model = BackgroundExtraction.BackgroundModel
    func img(_ w: Int, _ h: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    func img(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: ch, pixels: px, sourceIsLinear: true)
    }

    func testIdenticalModelsAreByteIdentical() {
        let a = img(2, 2, (0..<12).map { Float($0) / 12 })
        let m = Model(degree: 1, width: 2, height: 2, coeffPerChannel: [[0.1, 0.2, 0.0], [0, 0, 0], [0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: m, refModel: m).pixels, a.pixels)
    }

    func testSubtractsModelDifferenceForChannel() {
        // 2x1x3, ch0 flat 0.5. Sub model ch0 has a constant +0.1 more than ref → subtract 0.1.
        let a = img(2, 1, 3, [0.5, 0.5, 0.3, 0.3, 0.2, 0.2])
        let sub = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let ref = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.0, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.4, accuracy: 1e-6)        // ch0: 0.5 - (0.1-0.0) = 0.4
        XCTAssertEqual(out.pixels[1], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[2], 0.3, accuracy: 1e-6)        // ch1 nil coeff → passthrough
    }

    func testNilCoeffChannelPassesThrough() {
        let a = img(1, 1, 3, [0.5, 0.6, 0.7])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [nil, [0.2, 0, 0], nil])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        // ch0 ref-only or sub-nil → passthrough; ch1 ref nil → passthrough; ch2 both nil → passthrough
        XCTAssertEqual(out.pixels, [0.5, 0.6, 0.7])
    }

    func testClampsToUnitRange() {
        let a = img(1, 1, 3, [0.05, 0.95, 0.5])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.2, 0, 0], [-0.2, 0, 0], [0, 0, 0]])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.0, accuracy: 1e-6)        // 0.05 - 0.2 → clamp 0
        XCTAssertEqual(out.pixels[1], 1.0, accuracy: 1e-6)        // 0.95 - (-0.2) → clamp 1
    }

    func testParallelEqualsSerial() {
        let n = 200
        let px = (0..<(n*n*3)).map { Float($0 % 100) / 100 }
        let a = img(n, n, px)
        let sub = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0.1, 0.05, 0.02, 0.01, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        let ref = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: .max).pixels,
                       GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: 1).pixels)
    }

    // --- NEW TESTS (R3) ---

    /// Regression: sub degree-2 (6 coeffs) vs ref degree-1 (3 coeffs).
    /// Pre-fix: zip truncates to 3, evaluate(deg2) indexes coeff[3..5] → crash (exit 133).
    /// Post-fix: each model evaluated with its OWN degree; output = pixel - (surfDeg2 - surfDeg1).
    func testDegreeMismatchSubDeg2RefDeg1() {
        // 2×1 image, single channel (channels=3, only ch0 has coeffs).
        // sub: degree 2, constant term 0.1 only (coeff = [0.1, 0, 0, 0, 0, 0])
        //   → surfSub = 0.1 everywhere
        // ref: degree 1, constant term 0.05 (coeff = [0.05, 0, 0])
        //   → surfRef = 0.05 everywhere
        // expected correction: surfSub - surfRef = 0.05 everywhere
        // pixel 0: 0.5 - 0.05 = 0.45
        // pixel 1: 0.6 - 0.05 = 0.55
        let px: [Float] = [0.5, 0.6,   // ch0
                           0.0, 0.0,   // ch1 (nil)
                           0.0, 0.0]   // ch2 (nil)
        let a = AstroImage(width: 2, height: 1, channels: 3, pixels: px, sourceIsLinear: true)
        let sub = BackgroundExtraction.BackgroundModel(
            degree: 2, width: 2, height: 1,
            coeffPerChannel: [[0.1, 0.0, 0.0, 0.0, 0.0, 0.0], nil, nil])
        let ref = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 2, height: 1,
            coeffPerChannel: [[0.05, 0.0, 0.0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.45, accuracy: 1e-5)  // 0.5 - (0.1 - 0.05)
        XCTAssertEqual(out.pixels[1], 0.55, accuracy: 1e-5)  // 0.6 - (0.1 - 0.05)
        // ch1, ch2 nil → passthrough
        XCTAssertEqual(out.pixels[2], 0.0, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[3], 0.0, accuracy: 1e-6)
    }

    /// Reverse mismatch: sub degree-1 vs ref degree-2.
    /// Pre-fix: zip truncates ref to 3 coeffs, dropping quadratic terms → ref quadratic silently dropped.
    /// Post-fix: ref evaluated with degree-2, quadratic term IS subtracted.
    func testDegreeMismatchSubDeg1RefDeg2QuadraticNotDropped() {
        // 1×1 image at normalized coord (0,0): basis deg1=[1,0,0], deg2=[1,0,0,0,0,0]
        // sub: degree 1, coeff=[0.3, 0, 0] → surfSub at (0,0) = 0.3
        // ref: degree 2, coeff=[0.1, 0, 0, 0.2, 0, 0] → surfRef at (0,0) = 0.1 + 0.2*(0^2) = 0.1
        //   (nx = 0/1*2-1 = -1 for x=0 in a 1-wide image)
        //   Actually for 1×1: nx = Double(0)/Double(1)*2 - 1 = -1, ny = -1
        //   deg2 basis = [1, nx, ny, nx*nx, nx*ny, ny*ny] = [1, -1, -1, 1, 1, 1]
        //   surfSub = 0.3*1 + 0*(-1) + 0*(-1) = 0.3
        //   surfRef = 0.1*1 + 0*(-1) + 0*(-1) + 0.2*1 + 0*1 + 0*1 = 0.3
        //   correction = surfSub - surfRef = 0.3 - 0.3 = 0.0 → pixel unchanged
        // To make the quadratic term visible, use a pixel value not at nx=0.
        // Use 2×1 so we get nx=-1 (x=0) and nx=1 (x=1).
        // sub: deg1 coeff=[0.3, 0, 0] → surf = [0.3, 0.3]
        // ref: deg2 coeff=[0.1, 0, 0, 0.2, 0, 0] → surf at nx=-1: 0.1+0.2=0.3; at nx=+1: 0.1+0.2=0.3
        //   Hmm, nx²=1 in both cases. Use a linear ref term to distinguish.
        // ref: deg2 coeff=[0.1, 0.1, 0, 0, 0, 0] → surf at nx=-1: 0.1-0.1=0.0; at nx=+1: 0.1+0.1=0.2
        // sub: deg1 coeff=[0.1, 0.1, 0, 0, 0, 0] ... but sub is deg1 so only 3 coeffs
        // sub: deg1 coeff=[0.1, 0.1, 0] → surf at nx=-1: 0.1-0.1=0.0; at nx=+1: 0.1+0.1=0.2
        // correction = 0 - 0 = 0 at both pixels → uninformative.
        //
        // Better: linear parts match exactly, but ref has an extra quadratic term.
        // sub: deg1 coeff=[0.2, 0, 0]      → surf = [0.2, 0.2] (constant)
        // ref: deg2 coeff=[0.2, 0, 0, 0.1, 0, 0]
        //   at nx=-1: 0.2 + 0.1*1 = 0.3; at nx=+1: 0.2 + 0.1*1 = 0.3
        //   (nx² is always 1 at ±1 so same) — need interior point.
        //
        // Use 3×1 to get nx=-1, nx=0 (approx), nx=+1:
        //   nx = Double(x)/Double(3)*2 - 1: x=0→-1, x=1→-1/3, x=2→+1/3
        //   (3-wide: x=0→-1, x=1→-0.333, x=2→+0.333)
        // ref: deg2 coeff=[0.2, 0, 0, 0.1, 0, 0]
        //   x=0: surf = 0.2 + 0.1*1 = 0.3
        //   x=1: surf = 0.2 + 0.1*(1/9) = 0.2 + 0.0111 = 0.2111
        //   x=2: surf = 0.2 + 0.1*(1/9) = 0.2111
        // sub: deg1 coeff=[0.2, 0, 0] → surf = [0.2, 0.2, 0.2] everywhere
        // correction = sub - ref:
        //   x=0: 0.2 - 0.3 = -0.1   → pixel += 0.1
        //   x=1: 0.2 - 0.2111 = -0.0111 → pixel += 0.0111
        //   x=2: same as x=1
        // Pre-fix: zip truncates ref to [0.2, 0, 0] (deg1 parts), diff=[0,0,0] → passthrough (WRONG)
        // Post-fix: uses full ref quad surface → correction applied
        let px: [Float] = [0.5, 0.5, 0.5,   // ch0
                           0.0, 0.0, 0.0,   // ch1
                           0.0, 0.0, 0.0]   // ch2
        let a = AstroImage(width: 3, height: 1, channels: 3, pixels: px, sourceIsLinear: true)
        let sub = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 3, height: 1,
            coeffPerChannel: [[0.2, 0.0, 0.0], nil, nil])
        let ref = BackgroundExtraction.BackgroundModel(
            degree: 2, width: 3, height: 1,
            coeffPerChannel: [[0.2, 0.0, 0.0, 0.1, 0.0, 0.0], nil, nil])

        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)

        // Compute expected values using BackgroundExtraction.BackgroundModel.evaluate
        let sSub = BackgroundExtraction.BackgroundModel.evaluate(coeff: [0.2, 0.0, 0.0], degree: 1, width: 3, height: 1)
        let sRef = BackgroundExtraction.BackgroundModel.evaluate(coeff: [0.2, 0.0, 0.0, 0.1, 0.0, 0.0], degree: 2, width: 3, height: 1)

        for x in 0..<3 {
            let expected = (0.5 - (sSub[x] - sRef[x])).clamped(to: 0...1)
            XCTAssertEqual(out.pixels[x], expected, accuracy: 1e-5,
                           "Pixel \(x): ref quadratic term must be subtracted, not silently dropped")
        }
        // Verify the correction is non-trivial (ref quadratic IS applied)
        // At x=0: nx=-1, nx²=1 → sRef=0.2+0.1=0.3, sSub=0.2, correction=-0.1 → out[0]≈0.6
        XCTAssertGreaterThan(out.pixels[0], 0.55, "ref quadratic term must increase output at x=0")
    }

    /// NaN in a model coefficient → output pixel is finite and equals the original input (passthrough).
    func testNaNCoeffProducesFinitePassthrough() {
        let px: [Float] = [0.3, 0.6, 0.9,   // ch0
                           0.1, 0.2, 0.3,   // ch1 (passthrough: ref nil)
                           0.4, 0.5, 0.6]   // ch2 (passthrough: sub nil)
        let a = AstroImage(width: 3, height: 1, channels: 3, pixels: px, sourceIsLinear: true)
        // ch0 sub has a NaN coefficient → surface will be NaN → passthrough each pixel
        let sub = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 3, height: 1,
            coeffPerChannel: [[Double.nan, 0.0, 0.0], [0.1, 0, 0], nil])
        let ref = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 3, height: 1,
            coeffPerChannel: [[0.0, 0.0, 0.0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        // ch0: NaN coeff → each pixel passthrough (finite, equal to input)
        for x in 0..<3 {
            XCTAssert(out.pixels[x].isFinite, "Output pixel \(x) must be finite when NaN coeff encountered")
            XCTAssertEqual(out.pixels[x], px[x], accuracy: 1e-6,
                           "Output pixel \(x) must equal input (passthrough) when NaN coeff encountered")
        }
        // ch1: ref nil → passthrough
        for x in 3..<6 {
            XCTAssertEqual(out.pixels[x], px[x], accuracy: 1e-6)
        }
        // ch2: sub nil → passthrough
        for x in 6..<9 {
            XCTAssertEqual(out.pixels[x], px[x], accuracy: 1e-6)
        }
    }

    // --- FUSED SCALE TESTS ---

    /// Hand-computed fused case: out = surfRef + (x − surfSub)·scale.
    /// 1×1, surfSub const 0.1, surfRef const 0.05, x=0.3, s=1.5 → 0.05 + 0.2·1.5 = 0.35.
    func testFusedScaleHandComputed() {
        let a = img(1, 1, 3, [0.3, 0.0, 0.0])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.05, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref, scale: 1.5)
        XCTAssertEqual(out.pixels[0], 0.35, accuracy: 1e-6)   // 0.05 + (0.3 - 0.1)·1.5
    }

    /// Identical models WITH scale != 1 must NOT take the fast path:
    /// out = surfRef + (x − surfRef)·scale (surfSub == surfRef here).
    /// surf const 0.1, x=0.4, s=2.0 → 0.1 + (0.4 − 0.1)·2 = 0.7.
    func testIdenticalModelsWithScaleNotSkipped() {
        let a = img(1, 1, 3, [0.4, 0.0, 0.0])
        let m = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: m, refModel: m, scale: 2.0)
        XCTAssertEqual(out.pixels[0], 0.7, accuracy: 1e-6)   // 0.1 + (0.4 - 0.1)·2 — NOT byte-identical
    }

    /// scale: 1.0 (default) must be byte-identical to the old two-arg call — the fused form
    /// reduces to x − surfSub + surfRef.
    func testScaleOneByteIdenticalToDefault() {
        let a = img(2, 1, 3, [0.5, 0.5, 0.3, 0.3, 0.2, 0.2])
        let sub = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let ref = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.0, 0, 0], nil, nil])
        let defaulted = GradientLeveler.apply(a, subModel: sub, refModel: ref).pixels
        let explicitOne = GradientLeveler.apply(a, subModel: sub, refModel: ref, scale: 1.0).pixels
        XCTAssertEqual(defaulted, explicitOne)
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
