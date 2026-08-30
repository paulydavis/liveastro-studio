import XCTest
@testable import LiveAstroCore

final class GlobalCombineTests: XCTestCase {
    /// A single-channel image with a constant value; mask all in-bounds.
    private func img(_ w: Int, _ h: Int, _ v: Float) -> (AstroImage, [Float]) {
        (AstroImage(width: w, height: h, channels: 1,
                    pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true),
         [Float](repeating: 1, count: w*h))
    }

    func testRobustCenterIsMedianAndIgnoresOutlier() {
        // 5 frames: four ~1.0, one bright 9.0 trail. Median must be 1.0, unmoved by the outlier.
        let vals: [Float] = [1.0, 1.0, 1.0, 1.0, 9.0]
        let sample = vals.map { img(2, 2, $0) }
        let out = GlobalCombine.robustCenter(sample: sample)
        XCTAssertNotNil(out)
        for p in out!.center.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-6) }   // median, not mean (2.6)
        // MAD of {1,1,1,1,9} about median 1 = median{0,0,0,0,8} = 0 → scale 0 (all-equal core).
        for s in out!.scale { XCTAssertEqual(s, 0.0, accuracy: 1e-6) }
    }

    func testRobustCenterScaleIsMADScaled() {
        let vals: [Float] = [1.0, 2.0, 3.0, 4.0, 100.0]     // median 3; |v-3|={2,1,0,1,97}; MAD=1
        let sample = vals.map { img(1, 1, $0) }
        let out = GlobalCombine.robustCenter(sample: sample)!
        XCTAssertEqual(out.center.pixels[0], 3.0, accuracy: 1e-6)
        XCTAssertEqual(out.scale[0], 1.4826, accuracy: 1e-4)  // 1.4826 * MAD(=1)
    }

    func testRobustCenterNilOnEmpty() {
        XCTAssertNil(GlobalCombine.robustCenter(sample: []))
    }
}

extension GlobalCombineTests {
    private func wimg(_ w: Int, _ h: Int, _ v: Float, weight: Float) -> (AstroImage, [Float], Float) {
        (AstroImage(width: w, height: h, channels: 1,
                    pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true),
         [Float](repeating: 1, count: w*h), weight)
    }

    func testClippedWeightedMeanRemovesTrailAtN5() {
        // 5 frames, four = 1.0, one bright 9.0 (the "trail"). center=1, scale=0 → floor accepts all,
        // BUT with a tiny scale floor the trail is > center+kappa*floor and must be clipped.
        let frames = [wimg(2,2,1, weight: 1), wimg(2,2,1, weight: 1), wimg(2,2,1, weight: 1),
                      wimg(2,2,1, weight: 1), wimg(2,2,9, weight: 1)]
        let center = GlobalCombine.robustCenter(sample: frames.map { ($0.0, $0.1) })!  // center 1, MAD 0
        let out = GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.map { (image: $0.0, mask: $0.1, weight: $0.2) }.makeIterator()) },
            center: center.center, scale: center.scale, kappa: 3.0)!
        // Zero-MAD core: sigma = max(0, scaleFloor); |9-1| = 8 ≫ 3·floor → trail rejected.
        // Mean of the four 1.0 survivors == 1.0 (NOT (4*1+9)/5 = 2.6).
        for p in out.image.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-6) }
        for cov in out.coverage { XCTAssertEqual(cov, 5.0, accuracy: 1e-6) }   // depth = 5 frames covered
    }

    func testClippedWeightedMeanHonorsWeights() {
        // Two clean frames, values 2 and 4, weights 3 and 1 → weighted mean = (3*2+1*4)/4 = 2.5.
        let frames = [wimg(1,1,2, weight: 3), wimg(1,1,4, weight: 1)]
        let center = GlobalCombine.robustCenter(sample: frames.map { ($0.0, $0.1) })!  // median 3, MAD 1
        let out = GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.map { (image: $0.0, mask: $0.1, weight: $0.2) }.makeIterator()) },
            center: center.center, scale: center.scale, kappa: 5.0)!   // wide κ: keep both
        XCTAssertEqual(out.image.pixels[0], 2.5, accuracy: 1e-6)
    }

    func testClippedWeightedMeanKeepsSubFloorSpread() {
        // Two equal + one within-floor-window off. MAD = median{0,0,~1.8e-7} = 0 → sigma = scaleFloor
        // (1e-7); the outlier's deviation (2e-7 requested → ~1.8e-7 after Float32 rounding) < kappa·scaleFloor
        // (3e-7) → ALL kept. Pins that the floor doesn't over-reject small NUMERIC JITTER (not real 16-bit
        // quantization — that is ~1.5e-5). Values are chosen REPRESENTABLE in Float32; 0.5±1e-8 would round
        // back to 0.5 near the 0.5 ULP (~6e-8) and test nothing.
        let frames = [wimg(1,1,0.5, weight: 1), wimg(1,1,0.5, weight: 1), wimg(1,1,0.5 + 2e-7, weight: 1)]
        let center = GlobalCombine.robustCenter(sample: frames.map { ($0.0, $0.1) })!
        for s in center.scale { XCTAssertEqual(s, 0.0, accuracy: 1e-9) }       // MAD == 0 → floor path exercised
        let out = GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.map { (image: $0.0, mask: $0.1, weight: $0.2) }.makeIterator()) },
            center: center.center, scale: center.scale, kappa: 3.0)!
        for cov in out.coverage { XCTAssertEqual(cov, 3.0, accuracy: 1e-6) }   // depth = 3 frames covered (NOT survival)
        // Survival proof: if the jitter frame were CLIPPED, the mean would be EXACTLY 0.5; kept, it is
        // 0.5 + ~6.7e-8. Assert strictly > 0.5 so a scale-floor regression (over-rejecting the jitter)
        // FAILS — the loose accuracy:1e-6 alone would pass both clipped (0.5) and kept (~0.50000007).
        XCTAssertGreaterThan(out.image.pixels[0], 0.5)
        XCTAssertEqual(out.image.pixels[0], 0.5, accuracy: 1e-6)               // sanity: still ~0.5
    }
}
