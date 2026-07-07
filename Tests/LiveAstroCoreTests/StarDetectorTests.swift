import XCTest
@testable import LiveAstroCore

final class StarDetectorTests: XCTestCase {
    /// Synthetic field: flat background + Gaussian stars at known sub-pixel positions.
    func makeField(width: Int = 256, height: Int = 256, background: Float = 0.05,
                   stars: [(x: Double, y: Double, amp: Float)]) -> [Float] {
        var px = [Float](repeating: background, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 6)...min(height - 1, Int(s.y) + 6) {
                for x in max(0, Int(s.x) - 6)...min(width - 1, Int(s.x) + 6) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += s.amp * Float(exp(-(dx * dx + dy * dy) / (2 * 1.5 * 1.5)))
                }
            }
        }
        return px
    }

    func testRecoversKnownPositions() {
        let truth: [(x: Double, y: Double, amp: Float)] =
            [(40.3, 60.7, 0.9), (200.5, 30.2, 0.7), (128.0, 128.0, 0.5), (60.8, 220.4, 0.3)]
        let field = makeField(stars: truth)
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 4)
        // flux-descending order matches amplitude order
        for (star, t) in zip(found, truth) {
            XCTAssertEqual(star.x, t.x, accuracy: 0.3)
            XCTAssertEqual(star.y, t.y, accuracy: 0.3)
        }
    }

    func testIgnoresHotPixels() {
        var field = makeField(stars: [(100.0, 100.0, 0.8)])
        field[50 * 256 + 50] = 1.0   // single hot pixel: area 1 < min area 3
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].x, 100.0, accuracy: 0.3)
    }

    func testHandlesGradientBackground() {
        // Linear gradient 0.02...0.20 across x plus one star — grid background absorbs the gradient
        var field = makeField(stars: [(180.0, 90.0, 0.6)])
        for y in 0..<256 { for x in 0..<256 { field[y * 256 + x] += 0.18 * Float(x) / 255 } }
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].x, 180.0, accuracy: 0.4)
    }

    func testEmptyFieldFindsNothing() {
        let field = [Float](repeating: 0.05, count: 256 * 256)
        XCTAssertEqual(StarDetector.detect(luminance: field, width: 256, height: 256).count, 0)
    }
}
