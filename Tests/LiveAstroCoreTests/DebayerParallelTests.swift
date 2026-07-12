import XCTest
@testable import LiveAstroCore

final class DebayerParallelTests: XCTestCase {
    func testParallelDebayerIsByteIdenticalToSerial() {
        let w = 150, h = 140
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 13 + 5) % 239) / 239 }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)

        let serial = Debayer.bilinear(cfa: cfa, pattern: .rggb, minRows: .max)
        let parallel = Debayer.bilinear(cfa: cfa, pattern: .rggb, minRows: 0)

        XCTAssertEqual(serial.pixels, parallel.pixels)
    }
}
