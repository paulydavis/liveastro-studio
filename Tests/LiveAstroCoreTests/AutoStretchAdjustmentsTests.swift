import XCTest
@testable import LiveAstroCore

final class AutoStretchAdjustmentsTests: XCTestCase {
    // A small linear RGB image with a spread of values.
    func linearImage() -> AstroImage {
        let w = 4, h = 4, n = w * h
        var px = [Float](repeating: 0, count: n * 3)
        for c in 0..<3 {
            for i in 0..<n { px[c * n + i] = Float(i) / Float(n - 1) } // 0…1 ramp per channel
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testNeutralByteIdenticalToPlainStretch() {
        let img = linearImage()
        let plain = AutoStretch.stretch(img)
        let neutral = AutoStretch.stretch(img, blackPoint: 0, midtoneStrength: 0)
        XCTAssertEqual(plain.pixels, neutral.pixels)   // exact byte-for-byte
    }

    /// Synthetic frame with the shape of real astro data: a TIGHT background (median 0.010,
    /// MADN ~7e-5, matching Paul's M51 master) plus a sparse bright population. The tightness
    /// is the whole point — it is what made the old black point inert.
    func astroLikeImage() -> AstroImage {
        let w = 64, h = 64, n = w * h
        var px = [Float](repeating: 0, count: n * 3)
        var seed: UInt64 = 0x5EED
        func next() -> Double {          // deterministic LCG; tests must not be random
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        for i in 0..<n {
            // Background: 0.010 with +/- 1e-4 of noise, so MADN lands near 7e-5.
            var v = 0.010 + (next() - 0.5) * 2e-4
            if i % 97 == 0 { v += 0.2 * next() }   // ~1% of pixels are stars
            for c in 0..<3 { px[c * n + i] = Float(v) }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testBlackPointDarkensTheRenderedBackground() {
        // Black point raises the shadow cut while the midtone stays at its AUTO value.
        //
        // This is the regression that matters. The old implementation clipped the LINEAR data
        // and then re-derived the midtone from the clipped statistics, which is solved to place
        // the background back at `targetBackground` — so the clip was undone almost exactly.
        // Measured on Paul's real M51 master, the old control moved the render by 0.00/255 at
        // 0.005 and 0.21/255 across its whole range. It was inert in the app, and this test
        // fails if that renormalisation ever comes back.
        let img = astroLikeImage()
        func backgroundLevel(_ bp: Double) -> Double {
            let out = AutoStretch.stretch(img, blackPoint: bp).pixels.map(Double.init).sorted()
            return out[out.count / 2]        // median == the background, stars are sparse
        }

        let neutral = backgroundLevel(0)
        // Neutral must land on targetBackground: that is what the auto-stretch is solved for,
        // and it anchors the comparisons below.
        XCTAssertEqual(neutral, 0.25, accuracy: 0.03)

        // Monotone darkening, and each step is visible (>= 8/255) rather than arithmetic noise.
        var previous = neutral
        for bp in [0.125, 0.25, 0.5] {
            let level = backgroundLevel(bp)
            XCTAssertLessThan(level, previous - 8.0 / 255.0,
                              "black point \(bp) must visibly darken the background")
            previous = level
        }
        // Full travel crushes the background to black: blackPointMaxMADN is chosen so the
        // useful range sits inside the slider rather than in a sliver at one end.
        XCTAssertLessThan(backgroundLevel(1.0), 2.0 / 255.0)
    }

    func testBlackPointLeavesTheBrightEndAlone() {
        // Only the shadow cut moves; a pixel at full scale must still render at full scale.
        // Guards against a "fix" that simply scales the whole frame down.
        let img = astroLikeImage()
        var px = img.pixels
        let plane = img.width * img.height
        for c in 0..<3 { px[c * plane] = 1.0 }
        let withHighlight = AstroImage(width: img.width, height: img.height, channels: 3,
                                       pixels: px, sourceIsLinear: true)
        for bp in [0.0, 0.25, 0.5, 1.0] {
            let out = AutoStretch.stretch(withHighlight, blackPoint: bp)
            XCTAssertEqual(Double(out.pixels[0]), 1.0, accuracy: 1e-6,
                           "black point \(bp) must not pull down the highlight")
        }
    }

    func testMidtoneStrengthDirection() {
        // Positive strength brightens mids (harder stretch): mean output rises.
        let img = linearImage()
        let neutral = AutoStretch.stretch(img, midtoneStrength: 0)
        let harder  = AutoStretch.stretch(img, midtoneStrength: 0.8)
        let gentler = AutoStretch.stretch(img, midtoneStrength: -0.8)
        func mean(_ a: [Float]) -> Double { Double(a.reduce(0, +)) / Double(a.count) }
        XCTAssertGreaterThan(mean(harder.pixels), mean(neutral.pixels))
        XCTAssertLessThan(mean(gentler.pixels), mean(neutral.pixels))
    }

    func testSaturationIdentityGreyAndMono() {
        // factor 1 → identity.
        let w = 2, h = 1
        let px: [Float] = [0.8, 0.2,   0.3, 0.6,   0.1, 0.9]  // R:[.8,.2] G:[.3,.6] B:[.1,.9]
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
        let same = AutoStretch.applySaturation(img, 1)
        XCTAssertEqual(same.pixels, px)

        // factor 0 → all channels equal luminance L, and L is preserved.
        let grey = AutoStretch.applySaturation(img, 0)
        for i in 0..<(w * h) {
            let L = 0.2126 * Double(px[i]) + 0.7152 * Double(px[w*h + i]) + 0.0722 * Double(px[2*w*h + i])
            XCTAssertEqual(Double(grey.pixels[i]),          L, accuracy: 1e-6)
            XCTAssertEqual(Double(grey.pixels[w*h + i]),    L, accuracy: 1e-6)
            XCTAssertEqual(Double(grey.pixels[2*w*h + i]),  L, accuracy: 1e-6)
        }

        // mono (1-channel) passthrough.
        let mono = AstroImage(width: 2, height: 1, channels: 1, pixels: [0.2, 0.7], sourceIsLinear: false)
        XCTAssertEqual(AutoStretch.applySaturation(mono, 0).pixels, mono.pixels)
    }
}
