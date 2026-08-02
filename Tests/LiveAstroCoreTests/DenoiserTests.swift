import XCTest
@testable import LiveAstroCore

// Effect-size floors: T1-BINDING (docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md).
// Values are the results-doc floors verbatim (gate PASSED 2026-08-02): observed
// stage-only reductions at s=0.5 under the amended flattest-tile metric, minus
// 5 pt margin (s1: min(M8 +49.2%, Veil +51.6%) - 5pt; s2: min(M8 +32.6%, Veil +56.0%) - 5pt).
// Reachable at s=0.5 because the blend amplitude is min(1, gain·s) via the T1-BINDING
// chromaBlendGain/lumaBlendGain constants (a bare-s mix could never hit 0.50/0.40);
// they remain FLOORS and graduate with T1's final gain values.
let s1MinChromaReduction: Float = 0.442
let s2MinSigmaReduction: Float = 0.276

final class DenoiserStage1Tests: XCTestCase {

    // MARK: helpers (deterministic LCG, PerformanceTests precedent)

    static func lcg(_ state: inout UInt64) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 33) / Float(1 << 31)   // 0..1
    }

    /// Coarse (8x block-mean) MAD sigma of a plane — the chroma-mottle metric in miniature.
    static func coarseSigma(_ a: [Float], w: Int, h: Int) -> Float {
        let d = 8, sw = w / d, sh = h / d
        var small = [Float](repeating: 0, count: sw * sh)
        for j in 0..<sh { for i in 0..<sw {
            var s: Float = 0
            for dy in 0..<d { for dx in 0..<d { s += a[(j*d+dy)*w + i*d+dx] } }
            small[j*sw + i] = s / Float(d*d)
        } }
        var v = small; v.sort()
        let med = v[v.count/2]
        var dev = small.map { abs($0 - med) }; dev.sort()
        return 1.4826 * dev[dev.count/2]
    }

    static func opponentPlanes(_ img: AstroImage) -> (y: [Float], c1: [Float], c2: [Float]) {
        let plane = img.width * img.height
        var y = [Float](repeating: 0, count: plane)
        var c1 = y, c2 = y
        for i in 0..<plane {
            let r = img.pixels[i], g = img.pixels[plane + i], b = img.pixels[2*plane + i]
            y[i] = (r + 2*g + b) * 0.25; c1[i] = r - g; c2[i] = b - g
        }
        return (y, c1, c2)
    }

    /// Flat luma 0.5 + coarse-scale chroma mottle: low-frequency C1/C2 noise made by
    /// nearest-upsampling 16x16 seeded noise to 128x128 (mimics the green/magenta splotches).
    static func mottleFixture() -> AstroImage {
        let w = 128, h = 128, plane = w * h
        var rng: UInt64 = 0xA5_7A0_011
        var coarse1 = [Float](repeating: 0, count: 16 * 16)
        var coarse2 = coarse1
        for i in 0..<256 {
            coarse1[i] = (lcg(&rng) - 0.5) * 0.08
            coarse2[i] = (lcg(&rng) - 0.5) * 0.08
        }
        var px = [Float](repeating: 0, count: plane * 3)
        for yy in 0..<h { for xx in 0..<w {
            let i = yy * w + xx
            let c1 = coarse1[(yy/8) * 16 + (xx/8)], c2 = coarse2[(yy/8) * 16 + (xx/8)]
            let y: Float = 0.5
            let g = y - (c1 + c2) * 0.25
            px[i] = c1 + g; px[plane + i] = g; px[2*plane + i] = c2 + g
        } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
    }

    // MARK: passthrough contracts (spec §2.1, verbatim)

    func testStrengthZeroIsByteIdentical() {
        var rng: UInt64 = 7
        let px = (0..<(96*96*3)).map { _ in Self.lcg(&rng) }
        let img = AstroImage(width: 96, height: 96, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0)
        XCTAssertEqual(out.pixels, img.pixels)          // exact, not approximate
    }

    func testTinyImagePassesThrough() {
        let px = [Float](repeating: 0.3, count: 63 * 64 * 3)
        let img = AstroImage(width: 63, height: 64, channels: 3, pixels: px, sourceIsLinear: false)
        XCTAssertEqual(Denoiser.apply(img, strength: 1).pixels, px)
    }

    func testConstantMonoIsUnchanged() {
        // Mono runs stage 2 only; on a constant plane blur == input, so output == input.
        let px = [Float](repeating: 0.42, count: 96 * 96)
        let img = AstroImage(width: 96, height: 96, channels: 1, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.8)
        for i in 0..<px.count { XCTAssertEqual(out.pixels[i], 0.42, accuracy: 1e-6) }
    }

    func testNaNPassesThroughUntouchedAndDoesNotSpread() {
        var rng: UInt64 = 11
        var px = (0..<(96*96*3)).map { _ in Self.lcg(&rng) * 0.1 + 0.3 }
        px[500] = .nan; px[96*96 + 700] = .infinity
        let img = AstroImage(width: 96, height: 96, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 0.7)
        XCTAssertTrue(out.pixels[500].isNaN)                       // untouched at its position
        XCTAssertTrue(out.pixels[96*96 + 700].isInfinite)
        for (i, v) in out.pixels.enumerated() where i != 500 && i != 96*96 + 700 {
            XCTAssertTrue(v.isFinite, "NaN leaked to index \(i)")
        }
    }

    func testUnsupportedChannelCountPassesThrough() {
        let px = [Float](repeating: 0.2, count: 96 * 96 * 2)
        let img = AstroImage(width: 96, height: 96, channels: 2, pixels: px, sourceIsLinear: false)
        XCTAssertEqual(Denoiser.apply(img, strength: 1).pixels, px)
    }

    // MARK: stage-1 fixtures

    func testChromaMottleSuppressedWhileLumaHolds() {
        let img = Self.mottleFixture()
        let before = Self.opponentPlanes(img)
        let out = Denoiser.apply(img, strength: 0.5)
        let after = Self.opponentPlanes(out)
        let s1b = Self.coarseSigma(before.c1, w: 128, h: 128)
        let s1a = Self.coarseSigma(after.c1, w: 128, h: 128)
        let s2b = Self.coarseSigma(before.c2, w: 128, h: 128)
        let s2a = Self.coarseSigma(after.c2, w: 128, h: 128)
        XCTAssertLessThanOrEqual(s1a, s1b * (1 - s1MinChromaReduction),
            "coarse C1 sigma \(s1b) -> \(s1a): below the T1-validated reduction floor")
        XCTAssertLessThanOrEqual(s2a, s2b * (1 - s1MinChromaReduction))
        // Luma untouched to 1e-5, not ~1 ulp (finding F5): opponent round-trip
        // rounding PLUS stage-2's float32 box-blur residuals on the nominally
        // flat luma plane both contribute — a ~1-ulp bound would be too tight.
        for i in 0..<after.y.count {
            XCTAssertEqual(after.y[i], before.y[i], accuracy: 1e-5, "luma moved at \(i)")
        }
    }

    func testNoChromaBleedAcrossLumaEdge() {
        // Two-tone luma (0.2 | 0.8) with opposite constant chroma per side: any blur
        // across the boundary drags C1 toward 0 near the edge; the luma-edge guard
        // must prevent it.
        let w = 128, h = 128, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for yy in 0..<h { for xx in 0..<w {
            let i = yy * w + xx
            let y: Float = xx < w/2 ? 0.2 : 0.8
            let c1: Float = xx < w/2 ? 0.10 : -0.10
            let g = y - c1 * 0.25
            px[i] = c1 + g; px[plane + i] = g; px[2*plane + i] = g
        } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
        let out = Denoiser.apply(img, strength: 1.0)
        let after = Self.opponentPlanes(out)
        // Assert no-bleed across the whole coarse-guard-protected band around the
        // boundary (columns w/2-6 ... w/2+6), not just the two centre columns the
        // full-res guard alone protects — this pins the coarse guard too.
        // EXPECTED RED at the starting constants: probe analysis shows the bilinear
        // upsample leaks the unguarded neighbour coarse cell's blur delta into
        // cols ±4-6 (|Δc1| up to ~0.07 vs the 0.01 tolerance). The intended fix is
        // a ONE-CELL DILATION of the coarse luma-edge guard (guard a coarse cell if
        // it OR any 4-neighbour straddles a strong luma edge) — implement the
        // dilation in BOTH the Swift engine and the Python prototype (mirror
        // exactly; it becomes part of the T1-validated structure), then this test
        // goes green. Do not widen the tolerance and do not shrink the band.
        for yy in 8..<(h - 8) {
            for xx in (w/2 - 6)...(w/2 + 6) {
                let expected: Float = xx < w/2 ? 0.10 : -0.10
                XCTAssertEqual(after.c1[yy * w + xx], expected, accuracy: 0.01,
                    "chroma bled across luma edge (col \(xx), row \(yy))")
            }
        }
    }
}
