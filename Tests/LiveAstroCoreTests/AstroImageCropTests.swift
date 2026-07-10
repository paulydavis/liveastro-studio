import XCTest
@testable import LiveAstroCore

final class AstroImageCropTests: XCTestCase {
    func testCropMonoInteriorRect() {
        // 4x4 mono, pixel value = y*10 + x
        var px = [Float](repeating: 0, count: 16)
        for y in 0..<4 { for x in 0..<4 { px[y*4 + x] = Float(y*10 + x) } }
        let img = AstroImage(width: 4, height: 4, channels: 1, pixels: px, sourceIsLinear: true)
        // crop to columns 1..2, rows 1..2 (inclusive) => 2x2
        let out = img.cropped(to: CropRect(x0: 1, y0: 1, x1: 2, y1: 2))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2); XCTAssertEqual(out.channels, 1)
        XCTAssertEqual(out.pixels, [11, 12, 21, 22])
        XCTAssertEqual(out.sourceIsLinear, true)
    }

    func testCropRGBKeepsChannelsSeparate() {
        // 2x2, 3 channels; plane=4. channel c fills value = c*100 + (y*2+x)
        let plane = 4
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 { for y in 0..<2 { for x in 0..<2 {
            px[c*plane + y*2 + x] = Float(c*100 + y*2 + x)
        }}}
        let img = AstroImage(width: 2, height: 2, channels: 3, pixels: px, sourceIsLinear: false)
        // crop to the single pixel (1,1)
        let out = img.cropped(to: CropRect(x0: 1, y0: 1, x1: 1, y1: 1))
        XCTAssertEqual(out.width, 1); XCTAssertEqual(out.height, 1); XCTAssertEqual(out.channels, 3)
        // pixel (1,1) per channel: c*100 + 3
        XCTAssertEqual(out.pixels, [3, 103, 203])
    }

    func testFullFrameCropIsIdentity() {
        let px: [Float] = (0..<9).map { Float($0) }
        let img = AstroImage(width: 3, height: 3, channels: 1, pixels: px, sourceIsLinear: true)
        let out = img.cropped(to: CropRect(x0: 0, y0: 0, x1: 2, y1: 2))
        XCTAssertEqual(out.width, 3); XCTAssertEqual(out.height, 3)
        XCTAssertEqual(out.pixels, px)
    }
}
