import XCTest
@testable import LiveAstroCore

final class StackEngineTests: XCTestCase {
    /// Gray CFA starfield: same value at every CFA site → debayer yields R≈G≈B.
    func cfaFrame(width: Int = 512, height: Int = 512,
                  stars: [(x: Double, y: Double)], amp: Float = 0.8,
                  name: String = "test.fit") -> RawFrame {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += amp * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    func testSeedsOnFirstStarryFrame() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: [])), .rejected(.insufficientStars(found: 0)))
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        XCTAssertEqual(engine.acceptedCount, 1)
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    func testStacksTranslatedFrame() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }
        XCTAssertEqual(engine.process(cfaFrame(stars: shifted)), .stacked(frameCount: 2))
        // Stack keeps stars at REFERENCE positions: local max near (60.2, 80.5)
        let stack = engine.currentStack()!
        let plane = stack.width * stack.height
        let lum = { (x: Int, y: Int) -> Float in
            (0..<stack.channels).reduce(Float(0)) { $0 + stack.pixels[$1 * plane + y * stack.width + x] }
        }
        XCTAssertGreaterThan(lum(60, 80), lum(65, 78) + 0.0)   // peak stayed put (not doubled/moved)
        XCTAssertGreaterThan(lum(60, 80), 0.5)
    }

    func testRejectsStarlessFrameAfterSeeding() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let outcome = engine.process(cfaFrame(stars: []))
        XCTAssertEqual(outcome, .rejected(.insufficientStars(found: 0)))
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    func testReseedRestarts() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        _ = engine.process(cfaFrame(stars: field))
        engine.reseed()
        XCTAssertNil(engine.currentStack())
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
    }

    func testDimensionMismatchRejected() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let small = cfaFrame(width: 256, height: 256, stars: [(100, 100), (50, 200), (200, 60)])
        XCTAssertEqual(engine.process(small), .rejected(.dimensionMismatch))
    }

    func testBottomUpFrameFlipped() {
        // Same field delivered bottom-up must land at flipped y in the stack
        let engine = StackEngine()
        let f = cfaFrame(stars: field)
        let flipped = RawFrame(image: f.image, bayerPattern: .grbg, bottomUp: true,
                               timestamp: f.timestamp, sourceName: f.sourceName)
        _ = engine.process(flipped)
        let stack = engine.currentStack()!
        let plane = stack.width * stack.height
        // star at stored (60.2, 80.5) appears near y = 512 − 1 − 80 in display orientation
        let yFlip = 512 - 1 - 80
        XCTAssertGreaterThan(stack.pixels[plane + yFlip * 512 + 60], 0.3)   // G channel
    }
}
