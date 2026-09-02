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

    /// Regression (F2b): a degenerate 1×N frame used to crash star detection instead
    /// of being rejected up front.
    func testDegenerateFrameRejectedWithoutCrash() {
        let engine = StackEngine()
        let img = AstroImage(width: 1, height: 8, channels: 1,
                             pixels: [Float](repeating: 0.5, count: 8), sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "thin.fit")
        XCTAssertEqual(engine.process(frame), .rejected(.dimensionMismatch))
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    /// K4: a mono frame (no bayerPattern) after a CFA reference registers fine but
    /// carries 1 channel against the debayered 3-channel accumulator — must reject.
    func testChannelMismatchRejected() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        let mono = cfaFrame(stars: field)
        let frame = RawFrame(image: mono.image, bayerPattern: nil, bottomUp: false,
                             timestamp: mono.timestamp, sourceName: "mono.fit")
        XCTAssertEqual(engine.process(frame), .rejected(.dimensionMismatch))
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    func testStacksRotatedFrame() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        // Same synthesizer, star positions rotated ~2° about the image center.
        let theta = 2.0 * Double.pi / 180
        let (c, s) = (cos(theta), sin(theta))
        let rotated = field.map { p -> (x: Double, y: Double) in
            let dx = p.x - 256, dy = p.y - 256
            return (x: 256 + dx * c - dy * s, y: 256 + dx * s + dy * c)
        }
        XCTAssertEqual(engine.process(cfaFrame(stars: rotated)), .stacked(frameCount: 2))
        // Stack keeps stars at REFERENCE positions (mirrors testStacksTranslatedFrame).
        let stack = engine.currentStack()!
        let plane = stack.width * stack.height
        let lum = { (x: Int, y: Int) -> Float in
            (0..<stack.channels).reduce(Float(0)) { $0 + stack.pixels[$1 * plane + y * stack.width + x] }
        }
        XCTAssertGreaterThan(lum(60, 80), lum(65, 78))
        XCTAssertGreaterThan(lum(60, 80), 0.5)
    }

    /// BGGR CFA starfield with a colored background (B > G > R per mosaic site) so a
    /// channel-mapping regression (e.g. R/B swap) shows up in the stacked medians.
    func bggrFrame(width: Int = 512, height: Int = 512,
                   stars: [(x: Double, y: Double)], amp: Float = 0.8,
                   name: String = "bggr.fit") -> RawFrame {
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                px[y * width + x] = y % 2 == 0
                    ? (x % 2 == 0 ? 0.09 : 0.05)   // B G
                    : (x % 2 == 0 ? 0.05 : 0.02)   // G R
            }
        }
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += amp * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .bggr, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    func testBGGRStacksThroughEngine() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(bggrFrame(stars: field)), .becameReference)
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }
        XCTAssertEqual(engine.process(bggrFrame(stars: shifted)), .stacked(frameCount: 2))
        let stack = engine.currentStack()!
        XCTAssertEqual(stack.channels, 3)
        // BGGR background paints B sites brightest and R sites darkest.
        XCTAssertGreaterThan(stack.stats[2].median, stack.stats[1].median)
        XCTAssertGreaterThan(stack.stats[1].median, stack.stats[0].median)
    }

    /// Mono starfield (no CFA/debayer) at `field` positions offset by (dx, dy). Used by the
    /// registration-payload tests, which don't care about debayer/color — just ≥15 stars.
    func starFrame(dx: Double, dy: Double, width: Int = 512, height: Int = 512,
                   amp: Float = 0.8) -> AstroImage {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in field {
            let sx = s.x + dx, sy = s.y + dy
            for y in max(0, Int(sy) - 8)...min(height - 1, Int(sy) + 8) {
                for x in max(0, Int(sx) - 8)...min(width - 1, Int(sx) + 8) {
                    let ddx = Double(x) - sx, ddy = Double(y) - sy
                    px[y * width + x] += amp * Float(exp(-(ddx * ddx + ddy * ddy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        return AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
    }

    /// A RawFrame that seeds an engine (≥15 stars, untranslated field).
    func seedRaw() -> RawFrame {
        RawFrame(image: starFrame(dx: 0, dy: 0), bayerPattern: nil, bottomUp: false,
                 timestamp: Date(timeIntervalSince1970: 0), sourceName: "seed.fit")
    }

    func testProcessDetailedSurfacesRegistrationForAcceptedSubs() throws {
        let engine = StackEngine()
        let ref = starFrame(dx: 0, dy: 0)      // helper producing a ≥15-star AstroImage
        let r1 = engine.processDetailed(RawFrame(image: ref, bayerPattern: nil, bottomUp: false,
                                                 timestamp: Date(timeIntervalSince1970: 0), sourceName: "ref.fit"))
        XCTAssertEqual(r1.outcome, .becameReference)
        let reg1 = try XCTUnwrap(r1.registration)
        XCTAssertEqual(reg1.transform, .identity)
        XCTAssertEqual(reg1.effectiveScale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(reg1.weight, 1.0, accuracy: 1e-6)
        let gen = reg1.stackGeneration                       // reference's referenceIdentity == its own
        // (in-memory test frames have nil identity; the grouping property is asserted below via reg2)

        let sub = starFrame(dx: 1.0, dy: -0.5)
        let r2 = engine.processDetailed(RawFrame(image: sub, bayerPattern: nil, bottomUp: false,
                                                 timestamp: Date(timeIntervalSince1970: 1), sourceName: "s1.fit"))
        XCTAssertEqual(r2.outcome, .stacked(frameCount: 2))
        let reg2 = try XCTUnwrap(r2.registration)
        XCTAssertNotEqual(reg2.transform, .identity)          // it moved
        XCTAssertEqual(reg2.stackGeneration, gen)             // same generation as its reference
        XCTAssertEqual(reg2.referenceIdentity, reg1.referenceIdentity)  // subs carry the reference's identity
        XCTAssertEqual(reg2.weight, r2.weight, accuracy: 1e-6)
    }

    func testRejectedSubHasNoRegistration() {
        let engine = StackEngine()
        _ = engine.processDetailed(seedRaw())                 // seed
        let bad = RawFrame(image: AstroImage(width: 64, height: 64, channels: 1,
                           pixels: [Float](repeating: 0.05, count: 64*64), sourceIsLinear: true),
                           bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "flat.fit")
        let r = engine.processDetailed(bad)                    // too few stars → rejected
        if case .rejected = r.outcome { XCTAssertNil(r.registration) } else { XCTFail("expected reject") }
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
