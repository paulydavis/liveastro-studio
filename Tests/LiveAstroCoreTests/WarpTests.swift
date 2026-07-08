import XCTest
@testable import LiveAstroCore

final class WarpTests: XCTestCase {
    func ramp(w: Int, h: Int) -> AstroImage {
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = Float(x) / Float(w) } }
        return AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
    }

    func testIdentityIsExact() {
        let img = ramp(w: 16, h: 12)
        let (out, mask) = Warp.apply(img, transform: .identity)
        for i in 0..<img.pixels.count {
            XCTAssertEqual(out.pixels[i], img.pixels[i], accuracy: 1e-6)
            XCTAssertEqual(mask[i], 1.0, accuracy: 1e-6)
        }
    }

    func testIntegerTranslation() {
        let img = ramp(w: 16, h: 12)
        let (out, mask) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 3, ty: 0))
        // out(x,y) = in(x-3,y): column 5 of output equals column 2 of input
        XCTAssertEqual(out.pixels[5], img.pixels[2], accuracy: 1e-6)
        // columns 0..2 have no source — masked out
        XCTAssertEqual(mask[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mask[2], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mask[3], 1.0, accuracy: 1e-6)
    }

    func testHalfPixelTranslationInterpolates() {
        let img = ramp(w: 16, h: 12)
        let (out, _) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 0.5, ty: 0))
        // out(5,0) = in(4.5,0) = mean of columns 4 and 5
        let expected = (img.pixels[4] + img.pixels[5]) / 2
        XCTAssertEqual(out.pixels[5], expected, accuracy: 1e-6)
    }

    func testThreeChannelWarpsAllPlanes() {
        let w = 8, h = 8, plane = 64
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 { for i in 0..<plane { px[c * plane + i] = Float(c) * 0.3 } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let (out, _) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 1, ty: 1))
        for c in 0..<3 {
            XCTAssertEqual(out.pixels[c * plane + 3 * w + 3], Float(c) * 0.3, accuracy: 1e-6)
        }
    }
}
