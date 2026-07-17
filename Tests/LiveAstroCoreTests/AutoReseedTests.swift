import XCTest
@testable import LiveAstroCore

final class AutoReseedTests: XCTestCase {
    // Build a CFA RawFrame with Gaussian stars at the given positions (mirror StackEngineTests.cfaFrame).
    func cfaFrame(width: Int = 512, height: Int = 512, stars: [(Double, Double)],
                  name: String = "t.fit") -> RawFrame {
        var px = [Float](repeating: 0.03, count: width * height)
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(height-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(width-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*width+x] += 0.9 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }
    // Two disjoint fields (different relative geometry → won't triangle-match each other).
    // fieldA: stars clustered in the upper-left quadrant
    let fieldA: [(Double, Double)] = [
        (16.0, 16.0), (63.0, 99.0), (110.0, 182.0), (157.0, 265.0), (204.0, 348.0),
        (251.0, 431.0), (298.0, 34.0), (345.0, 117.0), (392.0, 200.0), (439.0, 283.0),
        (486.0, 366.0), (63.0, 449.0), (110.0, 52.0), (157.0, 135.0), (204.0, 218.0),
        (251.0, 301.0), (298.0, 384.0), (345.0, 467.0), (392.0, 70.0), (439.0, 153.0)
    ]
    // fieldB: stars clustered in the lower-right quadrant — genuinely different pattern
    let fieldB: [(Double, Double)] = [
        (20.0, 20.0), (123.0, 51.0), (226.0, 82.0), (329.0, 113.0), (432.0, 144.0),
        (75.0, 175.0), (178.0, 206.0), (281.0, 237.0), (384.0, 268.0), (487.0, 299.0),
        (40.0, 330.0), (143.0, 361.0), (246.0, 392.0), (349.0, 423.0), (452.0, 454.0),
        (95.0, 485.0), (198.0, 46.0), (301.0, 77.0), (404.0, 108.0), (457.0, 459.0)
    ]

    func testAutoReseedsAfterSystematicNoTransform() {
        let engine = StackEngine(autoReseedThreshold: 6)
        XCTAssertEqual(engine.process(cfaFrame(stars: fieldA)), .becameReference)   // seed on A
        // 6 disjoint B frames → all noTransform; the 6th trips the reseed.
        for i in 0..<6 {
            XCTAssertEqual(engine.process(cfaFrame(stars: fieldB, name: "b\(i).fit")),
                           .rejected(.noTransform), "B\(i) should not match A")
        }
        XCTAssertEqual(engine.autoReseedCount, 1)
        XCTAssertEqual(try engine.finalizationState().stackState,
                       .awaitingSeedAfterReseed(manual: 0, auto: 1))
        // Reference was cleared → the next B frame re-seeds onto B.
        XCTAssertEqual(engine.process(cfaFrame(stars: fieldB, name: "seedB.fit")), .becameReference)
        XCTAssertEqual(try engine.finalizationState().stackState, .active)
        // Subsequent B frames now stack against the B reference.
        if case .stacked = engine.process(cfaFrame(stars: fieldB, name: "b_ok.fit")) {} else {
            XCTFail("expected B to stack against the new B reference")
        }
    }

    // Regression (cold-review Critical, 2026-07-12): auto-reseed cleared reference/
    // accumulator/baseline but NOT the rejection state, so the new field's seed frame
    // got σ-clipped against the OLD field's warmed-up stats. Manual reseed() reset it;
    // auto-reseed must too. Proof: an engine warmed on A then auto-reseeded to B must
    // produce a B-seed stack byte-identical to a fresh engine seeded on B directly.
    func testAutoReseedResetsRejectionState() {
        let engine = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8), autoReseedThreshold: 6)
        _ = engine.process(cfaFrame(stars: fieldA))                                   // seed A
        for i in 0..<10 { _ = engine.process(cfaFrame(stars: fieldA, name: "a\(i).fit")) }  // warm rejection past warmUp
        for i in 0..<6 { _ = engine.process(cfaFrame(stars: fieldB, name: "b\(i).fit")) }   // 6 noTransform → auto-reseed
        XCTAssertEqual(engine.autoReseedCount, 1)
        XCTAssertEqual(engine.process(cfaFrame(stars: fieldB, name: "seedB.fit")), .becameReference)
        let afterReseed = engine.currentStack()!

        // Control: fresh engine seeded on B with pristine rejection state.
        let fresh = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8), autoReseedThreshold: 6)
        XCTAssertEqual(fresh.process(cfaFrame(stars: fieldB, name: "seedB.fit")), .becameReference)
        let control = fresh.currentStack()!

        XCTAssertEqual(afterReseed.pixels.count, control.pixels.count)
        var maxDiff: Float = 0
        for (a, b) in zip(afterReseed.pixels, control.pixels) { maxDiff = max(maxDiff, abs(a - b)) }
        XCTAssertLessThan(maxDiff, 1e-6,
                          "auto-reseed must reset rejection — the B seed must not be clipped against field-A stats")
    }

    func testNoFalseReseedOnGoodReference() {
        let engine = StackEngine(autoReseedThreshold: 6)
        _ = engine.process(cfaFrame(stars: fieldA))                       // seed A
        // Good A frames with an occasional single mismatch, never 6 in a row.
        for i in 0..<12 {
            if i % 4 == 3 { _ = engine.process(cfaFrame(stars: fieldB, name: "x\(i).fit")) } // 1 mismatch
            else { _ = engine.process(cfaFrame(stars: fieldA, name: "a\(i).fit")) }          // matches → .stacked resets
        }
        XCTAssertEqual(engine.autoReseedCount, 0)
    }

    func testThresholdZeroDisables() {
        let engine = StackEngine(autoReseedThreshold: 0)
        _ = engine.process(cfaFrame(stars: fieldA))
        for i in 0..<20 { _ = engine.process(cfaFrame(stars: fieldB, name: "b\(i).fit")) }
        XCTAssertEqual(engine.autoReseedCount, 0)                          // never auto-reseeds
    }

    func testCloudFrameDoesNotResetTheRun() {
        // noTransform ×3, insufficientStars ×1 (starless), noTransform ×3 → still 6 noTransform → trips.
        let engine = StackEngine(autoReseedThreshold: 6)
        _ = engine.process(cfaFrame(stars: fieldA))
        for i in 0..<3 { _ = engine.process(cfaFrame(stars: fieldB, name: "n\(i).fit")) }
        XCTAssertEqual(engine.process(cfaFrame(stars: [])), .rejected(.insufficientStars(found: 0)))
        for i in 3..<6 { _ = engine.process(cfaFrame(stars: fieldB, name: "n\(i).fit")) }
        XCTAssertEqual(engine.autoReseedCount, 1)                          // cloud didn't reset the count
    }
}
