import XCTest
@testable import LiveAstroCore

/// Clean-room verification for `Debayer.malvar` (Malvar–He–Cutler, ICASSP 2004).
/// Correctness is proven against SYNTHETIC GROUND TRUTH via PSNR — never by comparing
/// to any GPL implementation.
final class DebayerMalvarTests: XCTestCase {

    // MARK: - Synthetic ground-truth helpers

    /// Deterministic synthetic RGB image (planar, 3-channel, 0…1). All the high-frequency
    /// structure (gratings, hard edges, bars, star dots) is SHARED across the three
    /// channels — only smooth low-frequency gradients differ per channel. This is the
    /// natural-image "constant-hue" regime Malvar targets: colour differences are
    /// low-frequency, so the gradient correction reconstructs the shared detail that
    /// bilinear blurs. No randomness → byte-reproducible.
    private func syntheticRGB(width w: Int, height h: Int) -> AstroImage {
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }
        for y in 0..<h {
            for x in 0..<w {
                let fx = Float(x) / Float(w), fy = Float(y) / Float(h)
                // Shared mid-frequency detail (identical in R, G, B → constant hue).
                // Mid-frequency gratings (wavelengths ~10–16 px, including diagonals) are
                // exactly where bilinear loses resolution and Malvar's gradient correction
                // recovers it. Amplitudes keep the signal inside (0,1) so clipping does not
                // inject aliasing harmonics that would break the constant-hue assumption.
                // The decisive band is near the chroma Nyquist (~4–6 px wavelength): the
                // red/blue planes are sampled only every 2 px, so bilinear collapses there,
                // while Malvar recovers the detail from the denser green channel. Plus some
                // mid-frequency energy for realism.
                var detail: Float = 0
                detail += 0.16 * sin(2 * .pi * 22 * fx)   // ~5.8 px wavelength (near chroma Nyquist)
                detail += 0.15 * sin(2 * .pi * 24 * fy)   // ~5.3 px wavelength
                detail += 0.09 * sin(2 * .pi * 10 * (fx + fy))
                detail += 0.08 * sin(2 * .pi * 8 * (fx - fy))
                // Smooth per-channel low-frequency base (differs per channel → real colour;
                // constant-hue because the difference is low-frequency).
                let rLow = 0.42 + 0.06 * fx
                let gLow = 0.46 + 0.05 * fy
                let bLow = 0.40 + 0.05 * (1 - fx)
                px[0 * plane + y * w + x] = clamp(rLow + detail)
                px[1 * plane + y * w + x] = clamp(gLow + detail)
                px[2 * plane + y * w + x] = clamp(bLow + detail)
                // Bright star dots on a sparse grid (single hot pixels, all channels).
                if x % 23 == 7 && y % 29 == 11 {
                    px[0 * plane + y * w + x] = 1.0
                    px[1 * plane + y * w + x] = 1.0
                    px[2 * plane + y * w + x] = 1.0
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    /// Sample a 3-channel RGB image into a single-channel CFA for `pattern` by keeping,
    /// at each site, only the channel that the pattern places there.
    private func sampleCFA(_ rgb: AstroImage, pattern: BayerPattern) -> AstroImage {
        let w = rgb.width, h = rgb.height, plane = w * h
        var cfa = [Float](repeating: 0, count: plane)
        for y in 0..<h {
            for x in 0..<w {
                let c = pattern.channel(row: y, col: x)
                cfa[y * w + x] = rgb.pixels[c * plane + y * w + x]
            }
        }
        return AstroImage(width: w, height: h, channels: 1, pixels: cfa, sourceIsLinear: true)
    }

    /// Per-channel PSNR (dB) of `test` vs `ref` (both 3-channel, MAX = 1.0).
    private func psnrPerChannel(_ test: AstroImage, _ ref: AstroImage) -> [Double] {
        let plane = ref.width * ref.height
        return (0..<3).map { c in
            var sse = 0.0
            for i in 0..<plane {
                let d = Double(test.pixels[c * plane + i] - ref.pixels[c * plane + i])
                sse += d * d
            }
            let mse = sse / Double(plane)
            return mse <= 0 ? 200.0 : 10 * log10(1.0 / mse)
        }
    }

    private func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }

    // MARK: - (a) PSNR gate: Malvar beats bilinear by ≥ 3 dB on every pattern

    func testMalvarBeatsBilinearPSNRAllPatterns() {
        let w = 128, h = 128
        let truth = syntheticRGB(width: w, height: h)
        for pattern in [BayerPattern.grbg, .rggb, .bggr, .gbrg] {
            let cfa = sampleCFA(truth, pattern: pattern)
            let mal = Debayer.malvar(cfa: cfa, pattern: pattern, minRows: 8)
            let bil = Debayer.bilinear(cfa: cfa, pattern: pattern, minRows: 8)
            let pMal = psnrPerChannel(mal, truth), pBil = psnrPerChannel(bil, truth)
            let mMal = mean(pMal)
            let mBil = mean(pBil)
            print(String(format: "Malvar PSNR [%@]: malvar=%.2f dB  bilinear=%.2f dB  gain=%+.2f dB | R:%+.2f G:%+.2f B:%+.2f",
                         pattern.rawValue, mMal, mBil, mMal - mBil,
                         pMal[0] - pBil[0], pMal[1] - pBil[1], pMal[2] - pBil[2]))
            XCTAssertGreaterThanOrEqual(mMal - mBil, 3.0,
                "\(pattern.rawValue): Malvar mean PSNR must beat bilinear by ≥3 dB "
                + "(malvar=\(mMal) dB, bilinear=\(mBil) dB) — wrong coefficients or pattern mapping")
        }
    }

    // MARK: - (b) Bottom-up GRBG phase pin — proves no R/B swap

    /// GRBG CFA with distinct per-channel constants (R=0.8, G=0.4, B=0.2). Each Malvar
    /// mask has unity gain, so on a per-channel-constant field it reconstructs each
    /// channel EXACTLY as its own constant — R→0.8, B→0.2. A swapped R/B mask (or a
    /// swapped horizontal/vertical green-site assignment) would put 0.2 in the R plane.
    /// Debayered in stored order (never flip the CFA), matching the `normalizeRowOrder:
    /// false` contract of the bilinear phase test.
    func testGRBGPhaseNoRedBlueSwap() {
        let w = 16, h = 16
        // GRBG rows: [G R G R], [B G B G], … → R at (even row, odd col), B at (odd row, even col).
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let isR = (y % 2 == 0 && x % 2 == 1)
                let isB = (y % 2 == 1 && x % 2 == 0)
                px[y * w + x] = isR ? 0.8 : (isB ? 0.2 : 0.4)
            }
        }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        // minRows below h so the Malvar interior actually runs (not the passthrough).
        let out = Debayer.malvar(cfa: cfa, pattern: .grbg, minRows: 4)
        let plane = w * h
        for i in 0..<plane {
            XCTAssertEqual(out.pixels[0 * plane + i], 0.8, accuracy: 1e-4, "R plane must hold R's value (no swap)")
            XCTAssertEqual(out.pixels[1 * plane + i], 0.4, accuracy: 1e-4, "G plane must hold G's value")
            XCTAssertEqual(out.pixels[2 * plane + i], 0.2, accuracy: 1e-4, "B plane must hold B's value (no swap)")
        }
    }

    // MARK: - (c) Contracts

    /// Below `minRows` the result is exactly the bilinear passthrough.
    func testTinyImagePassesThroughToBilinear() {
        let w = 8, h = 8
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { px[i] = Float((i * 37) % 100) / 100.0 }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let mal = Debayer.malvar(cfa: cfa, pattern: .rggb, minRows: 64)  // 8 < 64 → passthrough
        let bil = Debayer.bilinear(cfa: cfa, pattern: .rggb, minRows: 64)
        XCTAssertEqual(mal.pixels, bil.pixels, "tiny image (< minRows) must equal bilinear exactly")
    }

    /// NaN/Inf in the input must not propagate — every output value is finite and in [0,1].
    func testNaNInfSanitized() {
        let w = 96, h = 96
        var px = [Float](repeating: 0.3, count: w * h)
        px[0] = .nan
        px[50 * w + 40] = .infinity
        px[70 * w + 60] = -.infinity
        px[80 * w + 10] = .nan
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let out = Debayer.malvar(cfa: cfa, pattern: .grbg, minRows: 8)
        for v in out.pixels {
            XCTAssertTrue(v.isFinite, "output must be finite after NaN/Inf input")
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }

    /// Same input → same output, regardless of worker-band count.
    func testDeterministic() {
        let w = 96, h = 96
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { px[i] = Float((i * 131 + 7) % 251) / 251.0 }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let a = Debayer.malvar(cfa: cfa, pattern: .bggr, minRows: 8)
        let b = Debayer.malvar(cfa: cfa, pattern: .bggr, minRows: 8)
        XCTAssertEqual(a.pixels, b.pixels, "malvar must be deterministic for identical input")
    }

    // MARK: - Review regressions

    /// Stack-domain output must NOT be low-clamped: dark-subtracted CFAs carry
    /// negative noise, and rectifying it to 0 biases the accumulated background.
    /// A constant negative field (all masks unity-gain) must map to itself.
    func testNegativeCalibratedValuesArePreserved() {
        let w = 16, h = 16
        let px = [Float](repeating: -0.1, count: w * h)
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let out = Debayer.malvar(cfa: cfa, pattern: .rggb, minRows: 1)
        let minV = out.pixels.min() ?? 0
        XCTAssertLessThan(minV, 0, "Malvar must preserve negative stack-domain values, not clamp to 0")
        // Unity-gain masks on a constant field reproduce the constant.
        for v in out.pixels { XCTAssertEqual(v, -0.1, accuracy: 1e-5) }
    }

    /// A tall, skinny CFA (width < 5) must fall back to bilinear, not trap on
    /// the `2..<(w-2)` interior range.
    func testTallSkinnyCFAFallsBackWithoutCrash() {
        let w = 3, h = 96
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float(i % 7) / 7 }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let out = Debayer.malvar(cfa: cfa, pattern: .grbg)            // default minRows=64, h>=minRows
        let ref = Debayer.bilinear(cfa: cfa, pattern: .grbg)
        XCTAssertEqual(out.width, w); XCTAssertEqual(out.height, h); XCTAssertEqual(out.channels, 3)
        XCTAssertEqual(out.pixels, ref.pixels, "width<5 must delegate wholesale to bilinear")
    }

}
