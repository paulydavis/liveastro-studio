import XCTest
@testable import LiveAstroCore

final class FrameWeightTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ v: Float) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1, pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true)
    }

    func testWeightedAddIsWeightedAverage() {
        let w = 4, h = 4, ones = [Float](repeating: 1, count: 16)
        let acc = StackAccumulator(width: w, height: h, channels: 1)
        acc.add(img(w, h, 0.9), mask: ones, frameWeight: 2.0)   // good frame, weight 2
        acc.add(img(w, h, 0.3), mask: ones, frameWeight: 1.0)   // poor frame, weight 1
        // weighted mean = (2·0.9 + 1·0.3) / 3 = 0.7
        for v in acc.mean().pixels { XCTAssertEqual(v, 0.7, accuracy: 1e-5) }
    }

    func testFrameWeightOneEqualsUnweighted() {
        let w = 4, h = 4, ones = [Float](repeating: 1, count: 16)
        let a = StackAccumulator(width: w, height: h, channels: 1)
        a.add(img(w, h, 0.4), mask: ones)                       // default frameWeight 1.0
        let b = StackAccumulator(width: w, height: h, channels: 1)
        b.add(img(w, h, 0.4), mask: ones, frameWeight: 1.0)
        XCTAssertEqual(a.mean().pixels, b.mean().pixels)
    }

    func testFrameWeightHelperNeutralWhenOff() {
        let e = StackEngine(frameWeighting: false)
        XCTAssertEqual(e.frameWeight(stars: 5, sigma: 0.01), 1.0)   // off → always 1
    }

    func testFrameWeightNoisyFrameLowerThanSeed() {
        let e = StackEngine(frameWeighting: true)
        e.setWeightBaselineForTesting(stars: 100, sigma: 0.02)
        // same stars, 2× noisier → (0.02/0.04)^2 = 0.25 → clamped at wLo 0.25
        XCTAssertEqual(e.frameWeight(stars: 100, sigma: 0.04), 0.25, accuracy: 1e-6)
        // seed-equal inputs → 1.0
        XCTAssertEqual(e.frameWeight(stars: 100, sigma: 0.02), 1.0, accuracy: 1e-6)
        // far fewer stars → below 1
        XCTAssertLessThan(e.frameWeight(stars: 40, sigma: 0.02), 1.0)
    }
}
