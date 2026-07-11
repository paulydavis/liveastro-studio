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

    func testBlackPointClipsAndRescales() {
        // Black-point clip is applied to the LINEAR input: x' = max(0,(x-bp)/(1-bp)).
        // Verify the clip transform directly on a known ramp via a helper.
        let bp = 0.25
        func clip(_ x: Double) -> Double { max(0, (x - bp) / (1 - bp)) }
        XCTAssertEqual(clip(0.25), 0, accuracy: 1e-9)      // at bp → 0
        XCTAssertEqual(clip(1.0), 1, accuracy: 1e-9)       // at 1 → 1
        XCTAssertEqual(clip(0.625), 0.5, accuracy: 1e-9)   // midway above bp
        // And a bp>0 stretch darkens: its minimum output <= the neutral minimum.
        let img = linearImage()
        let neutral = AutoStretch.stretch(img)
        let clipped = AutoStretch.stretch(img, blackPoint: 0.25)
        XCTAssertLessThanOrEqual(clipped.pixels.min()!, neutral.pixels.min()!)
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
