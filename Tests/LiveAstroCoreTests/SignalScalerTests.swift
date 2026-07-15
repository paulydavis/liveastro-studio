// Tests/LiveAstroCoreTests/SignalScalerTests.swift
import XCTest
@testable import LiveAstroCore

final class SignalScalerTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: ch, pixels: px, sourceIsLinear: true)
    }

    func testScaleOneIsByteIdentical() {
        let a = img(2, 2, 3, (0..<12).map { Float($0) / 12 })
        XCTAssertEqual(SignalScaler.apply(a, scale: 1.0, background: [0.1, 0.1, 0.1]).pixels, a.pixels)
    }

    func testScalesSignalAboutPerChannelBackground() {
        // ch0 bg 0.1: 0.3 -> 0.1 + 0.2*1.5 = 0.4 ; ch1 bg 0.2: 0.2 -> 0.2 (at pivot, unchanged)
        let a = img(1, 1, 2, [0.3, 0.2])
        let out = SignalScaler.apply(a, scale: 1.5, background: [0.1, 0.2])
        XCTAssertEqual(out.pixels[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[1], 0.2, accuracy: 1e-6)
    }

    func testClampsBothEnds() {
        let a = img(1, 1, 1, [0.9])
        XCTAssertEqual(SignalScaler.apply(a, scale: 2.0, background: [0.1]).pixels[0], 1.0)  // 0.1+0.8*2 → clamp
        let b = img(1, 1, 1, [0.05])
        XCTAssertEqual(SignalScaler.apply(b, scale: 2.0, background: [0.2]).pixels[0], 0.0)  // 0.2-0.15*2 → clamp
    }

    func testParallelEqualsSerial() {
        let n = 200
        let px = (0..<(n*n*3)).map { Float($0 % 97) / 97 }
        let a = img(n, n, 3, px)
        XCTAssertEqual(SignalScaler.apply(a, scale: 1.3, background: [0.1, 0.2, 0.3], minRows: .max).pixels,
                       SignalScaler.apply(a, scale: 1.3, background: [0.1, 0.2, 0.3], minRows: 1).pixels)
    }
}
