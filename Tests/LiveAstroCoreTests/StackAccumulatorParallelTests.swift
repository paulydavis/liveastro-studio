import XCTest
@testable import LiveAstroCore

final class StackAccumulatorParallelTests: XCTestCase {
    func testParallelAddIsByteIdenticalToSerial() {
        let w = 180, h = 220, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<px.count { px[i] = Float((i * 3 + 1) % 211) / 211 }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        var mask = [Float](repeating: 1, count: plane)
        for i in stride(from: 0, to: plane, by: 7) { mask[i] = 0 }   // some uncovered pixels

        let serialAcc = StackAccumulator(width: w, height: h, channels: 3)
        serialAcc.add(img, mask: mask, minRows: .max)
        let parallelAcc = StackAccumulator(width: w, height: h, channels: 3)
        parallelAcc.add(img, mask: mask, minRows: 0)

        XCTAssertEqual(serialAcc.mean().pixels, parallelAcc.mean().pixels)
        XCTAssertEqual(serialAcc.coverage(), parallelAcc.coverage())
        XCTAssertEqual(serialAcc.frameCount, parallelAcc.frameCount)
    }
}
