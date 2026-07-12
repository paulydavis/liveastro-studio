import XCTest
@testable import LiveAstroCore

final class BackgroundExtractionTests: XCTestCase {
    // 3-channel linear image: flat sky `base` + a planar ramp `slope` across x (same each channel).
    func gradientImage(w: Int, h: Int, base: Float, slope: Float) -> AstroImage {
        var px = [Float](repeating: 0, count: w * h * 3)
        for c in 0..<3 {
            for y in 0..<h {
                for x in 0..<w {
                    px[c*w*h + y*w + x] = base + slope * Float(x) / Float(w - 1)
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    // background spread over a central sky region (avoids edge tiles).
    func skySpread(_ img: AstroImage) -> Float {
        let w = img.width, h = img.height, plane = w * h
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        for y in (h/4)..<(3*h/4) { for x in (w/4)..<(3*w/4) {
            let v = img.pixels[y*w + x]; lo = min(lo, v); hi = max(hi, v)
        } }
        return hi - lo
    }

    func testPlanarGradientRemoved() {
        // slope 0.5 → values 0.1…0.6; skySpread over the central half measures ~0.25.
        let img = gradientImage(w: 128, h: 128, base: 0.1, slope: 0.5)
        let before = skySpread(img)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        let after = skySpread(out)
        XCTAssertGreaterThan(before, 0.2)          // the input really has a ramp
        XCTAssertLessThan(after, before * 0.1)     // ramp largely removed (flat)
        XCTAssertEqual(out.width, 128); XCTAssertEqual(out.channels, 3)
    }

    func testNebulaPreserved() {
        var img = gradientImage(w: 128, h: 128, base: 0.1, slope: 0.4)
        var px = img.pixels
        let w = 128, h = 128, plane = w*h
        // bright Gaussian blob near center, all channels
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let dx = Double(x-64), dy = Double(y-64)
            px[c*plane + y*w + x] += Float(0.6 * exp(-(dx*dx+dy*dy)/(2*8.0*8.0)))
        } } }
        img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        // blob peak stands well above its local sky after flatten (signal not eaten)
        let peak = out.pixels[64*w + 64]
        let localSky = out.pixels[20*w + 20]
        XCTAssertGreaterThan(peak - localSky, 0.3)
    }

    func testQuadraticNeedsDegree2() {
        // curved gradient: base + k*(x-cx)^2 across the frame
        let w = 128, h = 128, plane = w*h
        var px = [Float](repeating: 0, count: plane*3)
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let nx = Double(x - w/2) / Double(w/2)
            px[c*plane + y*w + x] = Float(0.1 + 0.5 * nx * nx)
        } } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let deg1 = BackgroundExtraction.flatten(img, degree: 1)
        let deg2 = BackgroundExtraction.flatten(img, degree: 2)
        XCTAssertLessThan(skySpread(deg2), skySpread(deg1))   // quadratic flattens curvature better
    }

    func testFlatImageUnchangedWithinTolerance() {
        let w = 64, h = 64
        let img = AstroImage(width: w, height: h, channels: 3,
                             pixels: [Float](repeating: 0.2, count: w*h*3), sourceIsLinear: true)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        for i in 0..<out.pixels.count { XCTAssertEqual(out.pixels[i], 0.2, accuracy: 1e-3) }
    }

    func testMonoPassthrough() {
        let img = AstroImage(width: 8, height: 8, channels: 1,
                             pixels: [Float](repeating: 0.3, count: 64), sourceIsLinear: true)
        XCTAssertEqual(BackgroundExtraction.flatten(img, degree: 1).pixels, img.pixels)
    }
}
