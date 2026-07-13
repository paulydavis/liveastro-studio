// Tests/LiveAstroCoreTests/GradientLevelerTests.swift
import XCTest
@testable import LiveAstroCore

final class GradientLevelerTests: XCTestCase {
    typealias Model = BackgroundExtraction.BackgroundModel
    func img(_ w: Int, _ h: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    func img(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: ch, pixels: px, sourceIsLinear: true)
    }

    func testIdenticalModelsAreByteIdentical() {
        let a = img(2, 2, (0..<12).map { Float($0) / 12 })
        let m = Model(degree: 1, width: 2, height: 2, coeffPerChannel: [[0.1, 0.2, 0.0], [0, 0, 0], [0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: m, refModel: m).pixels, a.pixels)
    }

    func testSubtractsModelDifferenceForChannel() {
        // 2x1x3, ch0 flat 0.5. Sub model ch0 has a constant +0.1 more than ref → subtract 0.1.
        let a = img(2, 1, 3, [0.5, 0.5, 0.3, 0.3, 0.2, 0.2])
        let sub = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let ref = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.0, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.4, accuracy: 1e-6)        // ch0: 0.5 - (0.1-0.0) = 0.4
        XCTAssertEqual(out.pixels[1], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[2], 0.3, accuracy: 1e-6)        // ch1 nil coeff → passthrough
    }

    func testNilCoeffChannelPassesThrough() {
        let a = img(1, 1, 3, [0.5, 0.6, 0.7])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [nil, [0.2, 0, 0], nil])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        // ch0 ref-only or sub-nil → passthrough; ch1 ref nil → passthrough; ch2 both nil → passthrough
        XCTAssertEqual(out.pixels, [0.5, 0.6, 0.7])
    }

    func testClampsToUnitRange() {
        let a = img(1, 1, 3, [0.05, 0.95, 0.5])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.2, 0, 0], [-0.2, 0, 0], [0, 0, 0]])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.0, accuracy: 1e-6)        // 0.05 - 0.2 → clamp 0
        XCTAssertEqual(out.pixels[1], 1.0, accuracy: 1e-6)        // 0.95 - (-0.2) → clamp 1
    }

    func testParallelEqualsSerial() {
        let n = 200
        let px = (0..<(n*n*3)).map { Float($0 % 100) / 100 }
        let a = img(n, n, px)
        let sub = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0.1, 0.05, 0.02, 0.01, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        let ref = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: .max).pixels,
                       GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: 1).pixels)
    }
}
