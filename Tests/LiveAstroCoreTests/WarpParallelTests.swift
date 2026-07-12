import XCTest
@testable import LiveAstroCore

final class WarpParallelTests: XCTestCase {
    func testParallelWarpIsByteIdenticalToSerial() {
        let w = 160, h = 130
        var px = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<px.count { px[i] = Float((i * 7 + 3) % 251) / 251 }   // deterministic pattern
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let t = SimilarityTransform(scale: 1.02, rotation: 0.03, tx: 2.5, ty: -1.5)

        let serial = Warp.apply(img, transform: t, minRows: .max)   // force serial
        let parallel = Warp.apply(img, transform: t, minRows: 0)    // force parallel

        XCTAssertEqual(serial.image.pixels, parallel.image.pixels)
        XCTAssertEqual(serial.mask, parallel.mask)
    }
}
