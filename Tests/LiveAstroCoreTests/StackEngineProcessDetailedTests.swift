import XCTest
@testable import LiveAstroCore

/// Covers the `processDetailed` seam (Task 5): `process` must still delegate to it with
/// byte-identical outcomes, and the surfaced metrics must reflect what the native path
/// actually measured/applied. Synthetic-frame builders mirrored from StackEngineTests
/// (cfaFrame + field) since XCTestCase instance helpers aren't shared across test files.
final class StackEngineProcessDetailedTests: XCTestCase {
    /// Gray CFA starfield: same value at every CFA site → debayer yields R≈G≈B.
    /// Mirrors StackEngineTests.cfaFrame exactly.
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

    /// Mirrors StackEngineTests.field exactly.
    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    /// A seeded engine + a registrable (translated) follow-up frame, so `process` and
    /// `processDetailed` can be compared on equivalent independent engines.
    func testProcessDelegatesToProcessDetailed() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }
        let detailed = engine.processDetailed(cfaFrame(stars: shifted))

        let engine2 = StackEngine()
        _ = engine2.process(cfaFrame(stars: field))
        let plain = engine2.process(cfaFrame(stars: shifted))

        XCTAssertEqual(detailed.outcome, plain)
    }

    func testReferenceFrameReportsWeightOne() {
        let engine = StackEngine()
        let result = engine.processDetailed(cfaFrame(stars: field))
        XCTAssertEqual(result.outcome, .becameReference)
        XCTAssertEqual(result.weight, 1.0, accuracy: 1e-6)
        XCTAssertGreaterThan(result.starCount, 0)
    }

    func testStackedFrameReportsMeasuredStarsAndSigma() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }
        let result = engine.processDetailed(cfaFrame(stars: shifted))
        if case .stacked = result.outcome {
            XCTAssertGreaterThan(result.starCount, 0)
            XCTAssertGreaterThan(result.backgroundSigma, 0)
        } else {
            XCTFail("expected .stacked, got \(result.outcome)")
        }
    }
}
