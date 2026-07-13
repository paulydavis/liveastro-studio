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
}
