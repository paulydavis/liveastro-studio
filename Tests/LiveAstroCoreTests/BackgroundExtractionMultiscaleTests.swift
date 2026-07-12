import XCTest
@testable import LiveAstroCore

final class BackgroundExtractionMultiscaleTests: XCTestCase {
    // 3-channel image: flat base + a LOCAL corner glow (a low-order polynomial cannot remove this).
    func cornerGradientImage(w: Int, h: Int) -> AstroImage {
        var px = [Float](repeating: 0, count: w*h*3)
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let r = hypot(Double(x - w), Double(y - h)) / (0.5 * hypot(Double(w), Double(h)))
            let glow = 0.12 / (1 + exp(6*(r - 0.5)))
            px[c*w*h + y*w + x] = Float(0.06 + glow)
        } } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    // background spread over a central sky region.
    func skySpread(_ img: AstroImage) -> Float {
        let w = img.width, h = img.height
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        for y in (h/4)..<(3*h/4) { for x in (w/4)..<(3*w/4) {
            let v = img.pixels[y*w + x]; lo = min(lo, v); hi = max(hi, v)
        } }
        return hi - lo
    }

    func testLocalCornerGradientRemoved() {
        let img = cornerGradientImage(w: 256, h: 192)
        let before = skySpread(img)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        let after = skySpread(out)
        XCTAssertGreaterThan(before, 0.02)          // the corner glow really varies the sky
        XCTAssertLessThan(after, before * 0.3)      // multiscale flattens the LOCAL gradient
        XCTAssertEqual(out.width, 256); XCTAssertEqual(out.channels, 3)
    }

    func testFlatImageUnchangedWithinTolerance() {
        let w = 128, h = 128
        let img = AstroImage(width: w, height: h, channels: 3,
                             pixels: [Float](repeating: 0.2, count: w*h*3), sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        for v in out.pixels { XCTAssertEqual(v, 0.2, accuracy: 5e-3) }
    }

    func testBrightBlobPreserved() {
        let w = 256, h = 192
        var px = cornerGradientImage(w: w, h: h).pixels
        let plane = w*h
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let dx = Double(x-128), dy = Double(y-96)
            px[c*plane + y*w + x] += Float(0.5*exp(-(dx*dx+dy*dy)/(2*10.0*10.0)))
        } } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        let peak = out.pixels[96*w + 128], localSky = out.pixels[20*w + 20]
        XCTAssertGreaterThan(peak - localSky, 0.3)   // blob not eaten by the background model
    }

    func testMonoPassthrough() {
        let img = AstroImage(width: 8, height: 8, channels: 1,
                             pixels: [Float](repeating: 0.3, count: 64), sourceIsLinear: true)
        XCTAssertEqual(BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5).pixels, img.pixels)
    }

    func testNaNInputProducesFiniteOutput() {
        var px = cornerGradientImage(w: 64, h: 64).pixels
        px[100] = .nan; px[64*64 + 7] = .infinity
        let img = AstroImage(width: 64, height: 64, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        XCTAssertTrue(out.pixels.allSatisfy { $0.isFinite })
    }

    func testDeterministic() {
        let img = cornerGradientImage(w: 128, h: 96)
        let a = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        let b = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        XCTAssertEqual(a.pixels, b.pixels)
    }

}
