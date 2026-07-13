// Tests/LiveAstroCoreTests/BackgroundModelTests.swift
import XCTest
@testable import LiveAstroCore

final class BackgroundModelTests: XCTestCase {
    // 3-channel image with a known linear gradient in channel 0 (ch1/ch2 flat).
    func gradientImage(_ w: Int, _ h: Int) -> AstroImage {
        var px = [Float](repeating: 0.1, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            px[y*w + x] = 0.1 + 0.4 * Float(x) / Float(w - 1)     // ch0: left→right ramp
        } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testFitBackgroundReturnsDegree1CoeffsPerChannel() {
        let m = BackgroundExtraction.fitBackground(gradientImage(64, 64), degree: 1)
        XCTAssertEqual(m.degree, 1); XCTAssertEqual(m.coeffPerChannel.count, 3)
        XCTAssertNotNil(m.coeffPerChannel[0])                     // ch0 fit succeeded
        XCTAssertEqual(m.coeffPerChannel[0]!.count, 3)            // [1, x, y]
        XCTAssertGreaterThan(m.coeffPerChannel[0]![1], 0.1)       // positive x-slope for a left→right ramp
    }

    func testRawSurfaceReconstructsTheGradient() {
        let m = BackgroundExtraction.fitBackground(gradientImage(64, 64), degree: 1)
        let s = m.rawSurface(channel: 0)!
        // surface should rise left→right, spanning ~0.4 across the width
        XCTAssertGreaterThan(s[63], s[0] + 0.3)
    }

    func testEvaluateZeroCoeffsIsFlatZero() {
        let s = BackgroundExtraction.BackgroundModel.evaluate(coeff: [0, 0, 0], degree: 1, width: 8, height: 8)
        XCTAssertTrue(s.allSatisfy { $0 == 0 })
    }

    func testFlattenStillMatchesFitPlusEvaluate() {
        // The refactored flatten must equal fit→evaluate→subtract-surface+pedestal.
        let img = gradientImage(48, 48)
        let flat = BackgroundExtraction.flatten(img, degree: 1)
        // reconstruct manually from the model
        let m = BackgroundExtraction.fitBackground(img, degree: 1)
        let s = m.rawSurface(channel: 0)!
        let ped = s.min()!
        let plane = 48 * 48
        for i in 0..<plane {
            let expected = min(max(img.pixels[i] - s[i] + ped, 0), 1)
            XCTAssertEqual(flat.pixels[i], expected, accuracy: 1e-6)
        }
    }

    // MARK: - Mask-aware fitBackground tests (R2)

    /// Build a 3-channel image with a known left→right linear gradient in all channels.
    /// The right 40% of pixels are zeroed (simulating warped-frame border outside coverage).
    /// Returns (image, mask) where mask is 1 in the left 60%, 0 in the right 40%.
    private func borderZeroImage(w: Int, h: Int) -> (image: AstroImage, mask: [Float]) {
        let cutX = Int(Double(w) * 0.6)   // left 60% covered
        var px = [Float](repeating: 0, count: w * h * 3)
        var mask = [Float](repeating: 0, count: w * h)
        for c in 0..<3 {
            for y in 0..<h {
                for x in 0..<w {
                    // True gradient: 0.2 + 0.5*(x/w) — same across all channels
                    let trueVal = Float(0.2) + Float(0.5) * Float(x) / Float(w - 1)
                    if x < cutX {
                        px[c * w * h + y * w + x] = trueVal
                        if c == 0 { mask[y * w + x] = 1.0 }
                    } else {
                        px[c * w * h + y * w + x] = 0.0   // zeroed border
                        // mask stays 0
                    }
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        return (img, mask)
    }

    /// Reference: fit the same gradient on ONLY the covered region pixels (full-frame with only left 60%).
    /// We approximate "true" slope by fitting the gradient image without any zeroing.
    private func trueGradientSlope(w: Int, h: Int) -> Double {
        // Build the ideal image (no zeroing) and fit it
        let cutX = Int(Double(w) * 0.6)
        var px = [Float](repeating: 0, count: w * h * 3)
        for c in 0..<3 {
            for y in 0..<h {
                for x in 0..<cutX {
                    px[c * w * h + y * w + x] = Float(0.2) + Float(0.5) * Float(x) / Float(w - 1)
                }
                // Fill right portion with same gradient (ideal) for the reference image
                for x in cutX..<w {
                    px[c * w * h + y * w + x] = Float(0.2) + Float(0.5) * Float(x) / Float(w - 1)
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let m = BackgroundExtraction.fitBackground(img, degree: 1)
        // coeff[1] is the x-slope coefficient for channel 0
        return m.coeffPerChannel[0]?[1] ?? 0.0
    }

    /// Test 1 (border-zero bias): masked fit recovers the covered region's gradient;
    /// unmasked fit of the zero-bordered image is biased toward a lower slope.
    func testMaskedFitRecoversTrueGradientBiasFreeVsUnmasked() {
        let w = 80, h = 80
        let (img, mask) = borderZeroImage(w: w, h: h)
        let trueSlope = trueGradientSlope(w: w, h: h)

        // Masked fit: should closely match true slope
        let maskedModel = BackgroundExtraction.fitBackground(img, degree: 1, mask: mask)
        let maskedSlope = maskedModel.coeffPerChannel[0]?[1] ?? 0.0

        // Unmasked fit: biased by the zero-filled right 40%
        let unmaskedModel = BackgroundExtraction.fitBackground(img, degree: 1, mask: nil)
        let unmaskedSlope = unmaskedModel.coeffPerChannel[0]?[1] ?? 0.0

        // The masked slope should be closer to the true slope than the unmasked slope
        let maskedError = abs(maskedSlope - trueSlope)
        let unmaskedError = abs(unmaskedSlope - trueSlope)

        XCTAssertLessThan(maskedError, unmaskedError,
            "Masked fit (error \(maskedError)) should be closer to true slope (\(trueSlope)) than unmasked (error \(unmaskedError))")
        // Also assert the unmasked fit is noticeably biased (not just marginally)
        XCTAssertGreaterThan(unmaskedError, 0.05,
            "Unmasked fit on zero-bordered image should be visibly biased; slope \(unmaskedSlope) vs truth \(trueSlope)")
    }

    /// Test 2 (full-coverage mask == nil mask): identical coefficients (exact equality).
    func testFullCoverageMaskEqualsNilMask() {
        let w = 64, h = 64
        let img = gradientImage(w, h)
        // A mask of all-1s covers every pixel — should give exactly the same result as nil
        let allOnesMask = [Float](repeating: 1.0, count: w * h)

        let nilModel = BackgroundExtraction.fitBackground(img, degree: 1, mask: nil)
        let fullMaskModel = BackgroundExtraction.fitBackground(img, degree: 1, mask: allOnesMask)

        // Coefficients must be exactly equal (byte-identity requirement)
        for c in 0..<3 {
            switch (nilModel.coeffPerChannel[c], fullMaskModel.coeffPerChannel[c]) {
            case (nil, nil):
                break  // both nil is fine
            case (let a?, let b?):
                XCTAssertEqual(a.count, b.count)
                for i in 0..<a.count {
                    XCTAssertEqual(a[i], b[i], accuracy: 0,
                        "Channel \(c) coeff[\(i)]: nil-mask=\(a[i]) vs full-mask=\(b[i]) must be exactly equal")
                }
            default:
                XCTFail("Channel \(c): one model has nil coeffs, the other does not")
            }
        }
    }

    /// Test 3 (sliver mask → too few covered tiles): all-nil coeffs, no crash.
    func testSliverMaskProducesAllNilCoeffsNoCrash() {
        let w = 64, h = 64
        let img = gradientImage(w, h)
        // Mask covering only a tiny sliver (1 pixel wide column on the left) — far too few tiles
        var sliverMask = [Float](repeating: 0.0, count: w * h)
        for y in 0..<h { sliverMask[y * w + 0] = 1.0 }  // only column x=0

        let model = BackgroundExtraction.fitBackground(img, degree: 1, mask: sliverMask)

        // All channels should have nil coefficients (not enough covered tiles)
        for c in 0..<3 {
            XCTAssertNil(model.coeffPerChannel[c],
                "Channel \(c) should have nil coeffs when mask covers only a sliver")
        }
    }
}
