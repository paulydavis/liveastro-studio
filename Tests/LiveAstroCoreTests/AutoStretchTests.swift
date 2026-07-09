import XCTest
@testable import LiveAstroCore

final class AutoStretchTests: XCTestCase {
    func testMTFEndpointsAndIdentity() {
        XCTAssertEqual(AutoStretch.mtf(0, 0.3), 0)
        XCTAssertEqual(AutoStretch.mtf(1, 0.3), 1)
        XCTAssertEqual(AutoStretch.mtf(0.42, 0.5), 0.42, accuracy: 1e-9) // m=0.5 is identity
        XCTAssertEqual(AutoStretch.mtf(0.25, 0.25), 0.5, accuracy: 1e-9) // maps m to 0.5? No: MTF(m, m)=0.5
    }

    func testStretchPutsMedianNearTarget() {
        // Skewed dark linear image: background ~0.02 with noise, a few bright pixels.
        var rng = SystemRandomNumberGenerator()
        var px = (0..<10_000).map { _ in Float(0.02 + Double.random(in: -0.005...0.005, using: &rng)) }
        for i in 0..<20 { px[i * 500] = 0.8 }
        let img = AstroImage(width: 100, height: 100, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertEqual(out.stats[0].median, 0.25, accuracy: 0.05)
        XCTAssertTrue(out.stats[0].median > img.stats[0].median * 3, "should brighten dramatically")
    }

    func testStretchIsMonotonic() {
        let px: [Float] = [0.0, 0.01, 0.02, 0.05, 0.2, 1.0] + [Float](repeating: 0.02, count: 94)
        let img = AstroImage(width: 10, height: 10, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        for i in 1..<6 { XCTAssertGreaterThanOrEqual(out.pixels[i], out.pixels[i - 1]) }
        XCTAssertEqual(out.pixels[5], 1.0, accuracy: 1e-5)
    }

    func testLinkedChannelsPreserveRatios() {
        // Red channel brighter than blue everywhere; after linked stretch red stays >= blue.
        let plane = 100
        var px = [Float](repeating: 0.04, count: plane)        // R
        px += [Float](repeating: 0.02, count: plane)           // G
        px += [Float](repeating: 0.01, count: plane)           // B
        let img = AstroImage(width: 10, height: 10, channels: 3, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertGreaterThan(out.pixels[0], out.pixels[plane])       // R > G
        XCTAssertGreaterThan(out.pixels[plane], out.pixels[2*plane]) // G > B
    }

    func testMakeCGImage() {
        let img = AstroImage(width: 4, height: 2, channels: 3,
                             pixels: [Float](repeating: 0.5, count: 24), sourceIsLinear: false)
        let cg = AutoStretch.makeCGImage(img)
        XCTAssertEqual(cg?.width, 4)
        XCTAssertEqual(cg?.height, 2)
    }

    func testMakeCGImageMono() {
        let img = AstroImage(width: 4, height: 4, channels: 1,
                             pixels: [Float](repeating: 0.5, count: 16), sourceIsLinear: false)
        let cg = AutoStretch.makeCGImage(img)
        XCTAssertEqual(cg?.width, 4)
        XCTAssertEqual(cg?.height, 4)
    }

    func testNeutralizeBackgroundMatchesChannelMediansToGreen() {
        // 4x4 RGB, green-dominant background: R median 0.02, G median 0.10, B median 0.04
        let plane = 16
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane { px[i] = 0.02; px[plane + i] = 0.10; px[2 * plane + i] = 0.04 }
        // one "star" pixel per channel so data isn't perfectly uniform
        px[0] = 0.9; px[plane] = 0.95; px[2 * plane] = 0.85
        let img = AstroImage(width: 4, height: 4, channels: 3, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.neutralizeBackground(img)
        func median(_ c: Int) -> Float {
            var s = Array(out.pixels[c * plane..<(c + 1) * plane]); s.sort(); return s[plane / 2]
        }
        XCTAssertEqual(median(0), median(1), accuracy: 1e-4)
        XCTAssertEqual(median(2), median(1), accuracy: 1e-4)
        // green channel untouched
        XCTAssertEqual(out.pixels[plane + 5], 0.10, accuracy: 1e-6)
        // scaling clamps to [0,1]
        XCTAssertLessThanOrEqual(out.pixels.max()!, 1.0)
        // neutralization is a white-balance step, not a stretch — linearity is preserved
        XCTAssertTrue(out.sourceIsLinear)
    }

    func testNeutralizeBackgroundGrayscalePassthrough() {
        let img = AstroImage(width: 2, height: 2, channels: 1,
                             pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let out = AutoStretch.neutralizeBackground(img)
        XCTAssertEqual(out.pixels, img.pixels)
    }

    func testNeutralizeBackgroundZeroMedianChannelUnscaled() {
        // R median 0 → channel must be left unscaled (no divide-by-zero blowup)
        let plane = 16
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane { px[plane + i] = 0.10; px[2 * plane + i] = 0.05 }
        px[0] = 0.5
        let img = AstroImage(width: 4, height: 4, channels: 3, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.neutralizeBackground(img)
        XCTAssertEqual(out.pixels[0], 0.5, accuracy: 1e-6)
    }

    // MARK: - Additive background neutralization

    /// Tile-based low-percentile background estimate, mirroring the logic under test,
    /// so tests can assert channel backgrounds without reaching into private helpers.
    private func tileBackground(_ image: AstroImage, channel c: Int,
                                tilesPerAxis: Int = 48, percentile: Double = 20) -> Double {
        let w = image.width, h = image.height, plane = w * h, base = c * plane
        var tileMedians: [Double] = []
        for ty in 0..<tilesPerAxis {
            let y0 = ty * h / tilesPerAxis, y1 = (ty + 1) * h / tilesPerAxis
            for tx in 0..<tilesPerAxis {
                let x0 = tx * w / tilesPerAxis, x1 = (tx + 1) * w / tilesPerAxis
                if y1 <= y0 || x1 <= x0 { continue }
                var vals: [Float] = []
                for y in y0..<y1 { for x in x0..<x1 { vals.append(image.pixels[base + y * w + x]) } }
                vals.sort()
                let mid = vals.count / 2
                tileMedians.append(vals.count % 2 == 0 ? Double(vals[mid - 1] + vals[mid]) / 2
                                                       : Double(vals[mid]))
            }
        }
        tileMedians.sort()
        let p = min(max(percentile, 0), 100) / 100
        let idx = min(tileMedians.count - 1, max(0, Int((p * Double(tileMedians.count - 1)).rounded())))
        return tileMedians[idx]
    }

    func testAdditiveBNAlignsChannelBackgrounds() {
        // 96x96x3, flat per-channel offset + a few bright stars in one channel.
        let w = 96, h = 96, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            px[i] = 0.02             // R
            px[plane + i] = 0.05     // G
            px[2 * plane + i] = 0.03 // B
        }
        // Bright "star" pixels in the green channel (should survive, not be subtracted away).
        let starIdx = [10 * w + 10, 50 * w + 40, 80 * w + 70]
        for s in starIdx { px[plane + s] = 0.9 }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)

        let out = AutoStretch.neutralizeBackgroundAdditive(img)

        let bgR = tileBackground(out, channel: 0)
        let bgG = tileBackground(out, channel: 1)
        let bgB = tileBackground(out, channel: 2)
        XCTAssertEqual(bgR, bgG, accuracy: 1e-4)
        XCTAssertEqual(bgG, bgB, accuracy: 1e-4)

        // Star preserved: green was 0.9, offset removed is (0.05 - 0.02) = 0.03 → ~0.87.
        XCTAssertEqual(out.pixels[plane + starIdx[0]], 0.87, accuracy: 1e-4)
    }

    func testAdditiveBNGrayscalePassthrough() {
        let img = AstroImage(width: 2, height: 2, channels: 1,
                             pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let out = AutoStretch.neutralizeBackgroundAdditive(img)
        XCTAssertEqual(out.pixels, img.pixels)
    }

    func testAdditiveBNIgnoresBrightSignalInEstimate() {
        // Dark 0.02 sky everywhere, but one bright QUADRANT (0.8) in green only.
        let w = 96, h = 96, plane = w * h
        var px = [Float](repeating: 0.02, count: plane * 3)
        for y in 0..<(h / 2) {
            for x in 0..<(w / 2) { px[plane + y * w + x] = 0.8 }
        }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)

        // Low-percentile estimate must track the dark sky, not the bright quadrant.
        XCTAssertEqual(tileBackground(img, channel: 1), 0.02, accuracy: 1e-4)

        let out = AutoStretch.neutralizeBackgroundAdditive(img)
        // Dark green sky stays ~aligned to the other channels' 0.02 (offset ~0).
        let darkGreenIdx = plane + (h - 1) * w + (w - 1)
        XCTAssertEqual(out.pixels[darkGreenIdx], 0.02, accuracy: 1e-4)
        // Bright quadrant stays bright (not crushed).
        XCTAssertEqual(out.pixels[plane + 0], 0.8, accuracy: 1e-4)
    }
}
