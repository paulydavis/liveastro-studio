import XCTest
@testable import LiveAstroCore

final class HalfResLuminanceParallelTests: XCTestCase {
    func testParallelLuminanceIsByteIdenticalToSerial() {
        let w = 200, h = 300
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 11 + 2) % 233) / 233 }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: .rggb, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "t")

        let serial = StackEngine.halfResLuminance(frame: frame, minRows: .max)
        let parallel = StackEngine.halfResLuminance(frame: frame, minRows: 0)

        XCTAssertEqual(serial.lum, parallel.lum)
        XCTAssertEqual(serial.width, parallel.width)
        XCTAssertEqual(serial.height, parallel.height)
    }

    func testBottomUpParallelMatchesSerial() {
        let w = 200, h = 260
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 5 + 9) % 197) / 197 }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: .rggb, bottomUp: true,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "t")
        let serial = StackEngine.halfResLuminance(frame: frame, minRows: .max)
        let parallel = StackEngine.halfResLuminance(frame: frame, minRows: 0)
        XCTAssertEqual(serial.lum, parallel.lum)
    }
}
