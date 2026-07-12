import XCTest
@testable import LiveAstroCore

final class CalibratorTests: XCTestCase {
    func mono(_ w: Int, _ h: Int, _ px: [Float], bottomUp: Bool = false) -> RawFrame {
        RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                 bayerPattern: nil, bottomUp: bottomUp, timestamp: Date(), sourceName: "L.fit")
    }

    func assertPixelsEqual(_ a: [Float], _ b: [Float], accuracy: Float = 1e-5) {
        XCTAssertEqual(a.count, b.count)
        for (i, (av, bv)) in zip(a, b).enumerated() {
            XCTAssertEqual(av, bv, accuracy: accuracy, "pixel \(i)")
        }
    }

    func testNoMastersIsIdentity() {
        let f = mono(2, 2, [0.1, 0.2, 0.3, 0.4])
        let out = Calibrator(dark: nil, flat: nil).apply(f)
        assertPixelsEqual(out.image.pixels, f.image.pixels)
    }

    func testDarkSubtractsPedestal() {
        let dark = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true)
        let f = mono(2, 2, [0.3, 0.4, 0.5, 0.6])
        let out = Calibrator(dark: dark, flat: nil).apply(f)
        assertPixelsEqual(out.image.pixels, [0.2, 0.3, 0.4, 0.5])
    }

    func testFlatDividesAndNormalizes() {
        // flat = 0.5 multiplier everywhere → light / 0.5 = light × 2, clamped [0,1]
        let flat = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.5, 0.5, 0.5, 0.5], sourceIsLinear: true)
        let f = mono(2, 2, [0.1, 0.2, 0.3, 0.9])
        let out = Calibrator(dark: nil, flat: flat).apply(f)
        assertPixelsEqual(out.image.pixels, [0.2, 0.4, 0.6, 1.0])   // 0.9/0.5=1.8 → clamp 1.0
    }

    func testFlatZeroClampsNoNaN() {
        let flat = AstroImage(width: 1, height: 1, channels: 1, pixels: [0.0], sourceIsLinear: true)
        let f = mono(1, 1, [0.5])
        let out = Calibrator(dark: nil, flat: flat).apply(f)
        XCTAssertTrue(out.image.pixels[0].isFinite)
        XCTAssertEqual(out.image.pixels[0], 1.0)   // 0.5 / flatFloor → huge → clamp 1.0
    }

    func testDimensionMismatchSkipsMasterAndLogs() {
        let dark = AstroImage(width: 4, height: 4, channels: 1,
                              pixels: [Float](repeating: 0.1, count: 16), sourceIsLinear: true)
        let f = mono(2, 2, [0.3, 0.4, 0.5, 0.6])
        let cal = Calibrator(dark: dark, flat: nil)
        var logged = false; cal.onLog = { _ in logged = true }
        let out = cal.apply(f)
        assertPixelsEqual(out.image.pixels, f.image.pixels)   // dark skipped → unchanged
        XCTAssertTrue(logged)
    }

    func testBottomUpLightFlipsMasterForAlignment() {
        // Master dark (top-down) rows: r0=[0.0,0.0], r1=[0.5,0.5].
        let dark = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.0, 0.0, 0.5, 0.5], sourceIsLinear: true)
        // Bottom-up light rows (stored): r0=[0.6,0.6] (physical bottom), r1=[0.2,0.2].
        // Aligned dark for a bottom-up light = vertical flip → r0 subtracts 0.5, r1 subtracts 0.0.
        let f = mono(2, 2, [0.6, 0.6, 0.2, 0.2], bottomUp: true)
        let out = Calibrator(dark: dark, flat: nil).apply(f)
        assertPixelsEqual(out.image.pixels, [0.1, 0.1, 0.2, 0.2])
        XCTAssertTrue(out.bottomUp)   // orientation preserved for the engine
    }

    // apply() is called concurrently by the import worker pool; every concurrent
    // result must equal the serial calibration (the alignment/logging prefix is
    // now lock-guarded). Exercises a FRESH calibrator so alignment is computed
    // under concurrency (the worst case).
    func testApplyIsThreadSafeUnderConcurrentImport() {
        let dark = AstroImage(width: 4, height: 4, channels: 1,
                              pixels: (0..<16).map { Float($0) * 0.01 }, sourceIsLinear: true)
        let light = mono(4, 4, (0..<16).map { 0.5 + Float($0) * 0.01 })
        let serial = Calibrator(dark: dark, flat: nil).apply(light).image.pixels

        let cal = Calibrator(dark: dark, flat: nil)
        var oks = [Bool](repeating: false, count: 128)
        oks.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: 128) { i in
                buf[i] = cal.apply(light).image.pixels == serial
            }
        }
        XCTAssertTrue(oks.allSatisfy { $0 }, "concurrent apply() must match serial calibration")
    }
}
