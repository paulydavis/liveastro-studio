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
