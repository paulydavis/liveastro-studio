import XCTest
@testable import LiveAstroCore

final class StackEngineCoverageAccessorTests: XCTestCase {
    private func starFrame(_ w: Int, _ h: Int) -> RawFrame {
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {
            let sx = (i % 5) * (w / 6) + 20, sy = (i / 5) * (h / 6) + 20
            for y in (sy - 4)...(sy + 4) { for x in (sx - 4)...(sx + 4) {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * w + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / 5))
            } }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "s.fit")
    }

    func testCurrentStackAndCoverageIsAtomicAndConsistent() {
        let engine = StackEngine()
        XCTAssertNil(engine.currentStackAndCoverage(), "nil before any stack exists")
        XCTAssertTrue(engine.seedReference(starFrame(160, 120), minRows: .max))
        guard let (image, coverage) = engine.currentStackAndCoverage() else {
            return XCTFail("expected a stack after seeding")
        }
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 120)
        XCTAssertEqual(coverage?.count, 160 * 120, "coverage map is width*height")
    }
}
