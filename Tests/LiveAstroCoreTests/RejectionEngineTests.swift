import XCTest
@testable import LiveAstroCore

final class RejectionEngineTests: XCTestCase {
    /// Identical mono starfield (18 stars) so registration is identity (no warp shift);
    /// `streakRow` (if >= 0) paints a bright horizontal streak into this frame.
    func frame(streakRow: Int) -> RawFrame {
        let w = 128, h = 128
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<18 {
            let sx = (i * 37) % 116 + 6, sy = (i * 53) % 116 + 6
            for y in max(0, sy-3)...min(h-1, sy+3) {
                for x in max(0, sx-3)...min(w-1, sx+3) {
                    let dx = Double(x-sx), dy = Double(y-sy)
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/4))
                }
            }
        }
        if streakRow >= 0 { for x in 0..<w { px[streakRow*w+x] = 0.9 } }   // bright streak
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "f.fit")
    }

    /// Stack 20 identical frames; frame #10 carries a streak on row 40. Returns the
    /// stacked value at a streak pixel (row 40, col 64), for the given engine.
    func stackedStreakValue(_ engine: StackEngine) -> Float {
        for i in 0..<20 { _ = engine.process(frame(streakRow: i == 10 ? 40 : -1)) }
        let mean = engine.currentStack()!
        return mean.pixels[40 * mean.width + 64]
    }

    func testRejectionRemovesStreakThatNoRejectionDilutes() {
        let withReject = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8))
        let without = StackEngine()   // default NoRejection
        let r = stackedStreakValue(withReject)
        let n = stackedStreakValue(without)
        // NoRejection dilutes the 1-frame streak: ~ (0.9 + 19*0.05)/20 ≈ 0.0925
        XCTAssertGreaterThan(n, 0.08)
        // Winsorized clamps it away → close to the 0.05 background
        XCTAssertLessThan(r, 0.06)
        XCTAssertLessThan(r, n)       // rejection strictly cleaner
    }

    func testReseedResetsRejectionState() {
        let engine = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8))
        for _ in 0..<12 { _ = engine.process(frame(streakRow: -1)) }
        engine.reseed()
        // after reseed the next frame becomes the reference (fresh stats); no crash, stacks cleanly
        _ = engine.process(frame(streakRow: -1))
        XCTAssertNotNil(engine.currentStack())
    }
}
