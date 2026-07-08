import XCTest
@testable import LiveAstroCore

// ---------------------------------------------------------------------------
// PerformanceTests: verify that StackEngine.process() completes within 10 s
// wall-clock time on a synthesized full-sensor 26 MP GRBG frame
// (6248 × 4176 pixels = ~26 MP, matching the ZWO ASI2600MC-Air sensor size).
//
// The gate is measured with Date() (one-shot, no XCTest measure{} harness).
// If the gate fails, report BLOCKED with the measured time; do not optimize
// without controller approval (see brief §task-12).
// ---------------------------------------------------------------------------

final class PerformanceTests: XCTestCase {

    // MARK: – Frame synthesis

    /// Synthesize a GRBG CFA frame: flat background + 200 seeded Gaussian stars.
    ///
    /// - Parameters:
    ///   - width:   frame width in CFA pixels (must be even)
    ///   - height:  frame height in CFA pixels (must be even)
    ///   - dx:      horizontal position offset applied to every star (full-res px)
    ///   - dy:      vertical position offset applied to every star (full-res px)
    ///   - seed:    LCG seed — same seed + same (dx,dy) reproduces the frame exactly
    private func synthesizeFrame(width: Int, height: Int,
                                 dx: Double = 0, dy: Double = 0,
                                 seed: UInt64 = 0x1234_ABCD_EF01_2345) -> RawFrame {
        var pixels = [Float](repeating: 0.05, count: width * height)
        var rng: UInt64 = seed

        @inline(__always) func next() -> UInt64 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return rng
        }

        let margin = 20
        let xRange = UInt64(width  - 2 * margin)
        let yRange = UInt64(height - 2 * margin)

        for _ in 0..<200 {
            let cx = Double(next() % xRange) + Double(margin) + dx
            let cy = Double(next() % yRange) + Double(margin) + dy
            let amp = Float(0.6 + Double(next() % 40) / 100.0)
            let sigma = Double(2 + Int(next() % 3))   // 2, 3 or 4 CFA pixels
            let radius = Int(sigma * 4) + 1
            let xmin = max(0, Int(cx) - radius)
            let xmax = min(width  - 1, Int(cx) + radius)
            let ymin = max(0, Int(cy) - radius)
            let ymax = min(height - 1, Int(cy) + radius)
            for y in ymin...ymax {
                for x in xmin...xmax {
                    let ddx = Double(x) - cx, ddy = Double(y) - cy
                    pixels[y * width + x] +=
                        amp * Float(exp(-(ddx * ddx + ddy * ddy) / (2 * sigma * sigma)))
                }
            }
        }
        for i in 0..<pixels.count { pixels[i] = min(max(pixels[i], 0), 1) }

        let img = AstroImage(width: width, height: height, channels: 1,
                             pixels: pixels, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0),
                        sourceName: "perf_synth.fit")
    }

    // MARK: – Gate

    /// Full-sensor (6248 × 4176, ~26 MP) single-frame stacking performance gate.
    ///
    /// The reference frame seeds the engine, then we time one process() call on
    /// a copy shifted by (5, 3) pixels.  Wall-clock limit: 10 seconds.
    func testProcess26MPPerformanceGate() throws {
        #if DEBUG
        throw XCTSkip("perf gate is meaningful only with optimizations — run: swift test -c release --filter PerformanceTests")
        #endif
        let width = 6248, height = 4176   // even dimensions, GRBG-safe

        // Build reference and shifted frames (outside the timed region).
        let refFrame     = synthesizeFrame(width: width, height: height)
        let shiftedFrame = synthesizeFrame(width: width, height: height, dx: 5.0, dy: 3.0)

        let engine = StackEngine()
        let seedOutcome = engine.process(refFrame)
        XCTAssertEqual(seedOutcome, .becameReference,
            "Reference frame must seed the engine; got \(seedOutcome)")

        // ── Timed region ────────────────────────────────────────────────────
        let startTime = Date()
        let outcome = engine.process(shiftedFrame)
        let elapsed = Date().timeIntervalSince(startTime)
        // ── End timed region ─────────────────────────────────────────────────

        print("PerformanceTests · 26 MP process() elapsed: \(String(format: "%.2f", elapsed)) s")

        XCTAssertLessThan(elapsed, 10.0,
            "Performance gate FAILED: process() took \(String(format: "%.2f", elapsed)) s " +
            "(limit 10 s). Report BLOCKED — do not optimize without controller approval.")

        // The shifted frame should register and stack (log but don't fail on rejection).
        switch outcome {
        case .stacked(let n):
            print("PerformanceTests · stacked \(n) frames")
        case .rejected(let reason):
            // Log — registration failure on a synthetic frame is unexpected but not
            // a timing-gate failure.
            print("PerformanceTests · WARNING: frame rejected (\(reason)); " +
                  "timing gate still evaluated above.")
        case .becameReference:
            XCTFail("Unexpected .becameReference on second frame")
        }
    }
}
