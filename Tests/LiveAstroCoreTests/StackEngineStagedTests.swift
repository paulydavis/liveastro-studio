import XCTest
@testable import LiveAstroCore

final class StackEngineStagedTests: XCTestCase {
    // Gray CFA starfield (same generator as StackEngineTests).
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

    func testSeedReferenceSucceedsOnStarryFrameAndFailsOnEmpty() {
        let engine = StackEngine()
        XCTAssertFalse(engine.seedReference(cfaFrame(stars: []), minRows: Int.max))
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertTrue(engine.seedReference(cfaFrame(stars: field), minRows: Int.max))
        XCTAssertEqual(engine.acceptedCount, 1)
        XCTAssertEqual(engine.stackFrameCount, 1)
    }

    func testRegisterReturnsNilBeforeSeedAndForStarless() {
        let engine = StackEngine()
        // No reference yet → register returns nil (does not mutate).
        XCTAssertNil(engine.register(cfaFrame(stars: field), minRows: Int.max))
        XCTAssertEqual(engine.acceptedCount, 0)
        XCTAssertEqual(engine.rejectedCount, 0)
        _ = engine.seedReference(cfaFrame(stars: field), minRows: Int.max)
        XCTAssertNil(engine.register(cfaFrame(stars: []), minRows: Int.max))     // too few stars
    }

    func testStagedRegisterWarpCommitEqualsMonolithicProcess() {
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }

        // Monolithic reference: process seed then a translated frame.
        let mono = StackEngine()
        XCTAssertEqual(mono.process(cfaFrame(stars: field, name: "a")), .becameReference)
        XCTAssertEqual(mono.process(cfaFrame(stars: shifted, name: "b")), .stacked(frameCount: 2))

        // Staged: seed then register→warp→commit the same translated frame.
        let staged = StackEngine()
        XCTAssertTrue(staged.seedReference(cfaFrame(stars: field, name: "a"), minRows: Int.max))
        let reg = staged.register(cfaFrame(stars: shifted, name: "b"), minRows: Int.max)
        XCTAssertNotNil(reg)
        let w = staged.warp(reg!, minRows: Int.max)
        staged.commit(image: w.image, mask: w.mask, minRows: Int.max)

        XCTAssertEqual(staged.acceptedCount, mono.acceptedCount)   // both 2
        XCTAssertEqual(staged.stackFrameCount, mono.stackFrameCount)
        // Same code path, same order → byte-identical stack.
        XCTAssertEqual(staged.currentStack()!.pixels, mono.currentStack()!.pixels)
        XCTAssertEqual(staged.currentCoverage()!, mono.currentCoverage()!)
    }

    func testCommitRejectionBumpsRejectedCount() {
        let engine = StackEngine()
        _ = engine.seedReference(cfaFrame(stars: field), minRows: Int.max)
        engine.commitRejection()
        XCTAssertEqual(engine.rejectedCount, 1)
    }
}
