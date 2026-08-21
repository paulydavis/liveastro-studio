import XCTest
@testable import LiveAstroCore

/// `referenceSolveInput()` exposes the reference frame's detected stars + dimensions for plate-solving
/// (sub-project 3a). The stars are detected on the HALF-RES luminance, so the reported width/height are
/// half the full-res frame (raw.width/2, raw.height/2) — the space the star coordinates live in.
final class StackEngineReferenceSolveInputTests: XCTestCase {
    /// Gray CFA starfield (same pattern the other StackEngine tests use).
    private func cfaFrame(width: Int = 512, height: Int = 512,
                          stars: [(x: Double, y: Double)]) -> RawFrame {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "ref.fit")
    }

    private let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    func testReturnsNilBeforeSeed() {
        let engine = StackEngine()
        XCTAssertNil(engine.referenceSolveInput())
    }

    func testReturnsHalfResStarsAndSizeAfterSeed() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(width: 512, height: 512, stars: field)), .becameReference)
        let got = engine.referenceSolveInput()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.stars.count, 0)
        // half-res of the 512×512 full-res frame
        XCTAssertEqual(got!.width, 256)
        XCTAssertEqual(got!.height, 256)
        // stars live in the half-res coordinate space → all within the reported bounds
        for s in got!.stars {
            XCTAssertGreaterThanOrEqual(s.x, 0); XCTAssertLessThan(s.x, 256)
            XCTAssertGreaterThanOrEqual(s.y, 0); XCTAssertLessThan(s.y, 256)
        }
    }
}
