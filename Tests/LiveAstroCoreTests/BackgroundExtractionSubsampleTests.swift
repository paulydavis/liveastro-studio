import XCTest
@testable import LiveAstroCore

/// tileSamples subsamples large tiles so per-tile median cost stays bounded (the 2026-08-16
/// 26MP import stall: ~25k px/tile full-sorted, 2–3 calls/frame). These pin (1) the median
/// tracks the full-tile median within noise on a large tile, and (2) small tiles are exact.
final class BackgroundExtractionSubsampleTests: XCTestCase {

    /// Build a 3-channel image with a smooth per-channel gradient + sparse bright "stars".
    private func gradientWithStars(w: Int, h: Int) -> AstroImage {
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 {
            let base = c * plane
            for y in 0..<h { for x in 0..<w {
                px[base + y*w + x] = 0.10 + 0.05*Float(x)/Float(w) + 0.03*Float(y)/Float(h)
                    + Float((x*31 + y*17 + c*7) % 97) / 9700.0
            } }
        }
        var seed = 12345
        for _ in 0..<(plane/300) { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff
            let p = seed % plane; for c in 0..<3 { px[c*plane + p] = 0.9 } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    private func fullTileMedians(_ img: AstroImage, tiles: Int = 32, channel c: Int) -> [Double] {
        let w = img.width, h = img.height
        var out: [Double] = []
        for ty in 0..<tiles { let y0 = ty*h/tiles, y1 = (ty+1)*h/tiles; if y1<=y0 { continue }
            for tx in 0..<tiles { let x0 = tx*w/tiles, x1 = (tx+1)*w/tiles; if x1<=x0 { continue }
                var vals: [Float] = []
                for yy in y0..<y1 { for xx in x0..<x1 { vals.append(img.pixels[c*w*h + yy*w + xx]) } }
                vals.sort(); out.append(Double(vals[vals.count/2]))
            } }
        return out
    }

    func testLargeTileMedianTracksFullMedian() {
        // 1440x1440 / 32 tiles → ~2025 px/tile (> maxSamplesPerTile=1024) → the subsample
        // path is exercised, while the test's brute-force reference stays cheap.
        let img = gradientWithStars(w: 1440, h: 1440)
        let s = BackgroundExtraction.tileSamples(img)
        let full = fullTileMedians(img, channel: 0)
        XCTAssertEqual(s.v[0]!.count, full.count)
        let maxErr = zip(s.v[0]!, full).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxErr, 0.003, "subsampled tile median must track the full median within read noise")
    }

    func testSmallTilesAreExact() {
        // 128x128 with 32 tiles → 4x4 px tiles (<< maxSamplesPerTile) → sampled in full,
        // so the subsample path is never taken and medians are byte-for-byte the legacy value.
        let img = gradientWithStars(w: 128, h: 128)
        let s = BackgroundExtraction.tileSamples(img)
        let full = fullTileMedians(img, channel: 1)
        XCTAssertEqual(s.v[1]!, full, "small tiles must be sampled in full (identical to legacy)")
    }
}
