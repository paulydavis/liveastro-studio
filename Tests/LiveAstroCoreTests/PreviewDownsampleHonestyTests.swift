import XCTest
@testable import LiveAstroCore

/// The staged preview renders from a downsample. `AutoStretch` derives its transform from the
/// image's OWN median and MADN (`AutoStretch.swift:47-57`), so if downsampling moved those
/// statistics the preview would show a different stretch than the broadcast — a preview that
/// lies is worse than no preview. `AstroImageDownsampleTests` already covers the mechanics of
/// the downsample; this covers the property the preview design rests on, which nothing did.
final class PreviewDownsampleHonestyTests: XCTestCase {

    /// CORRECTED 2026-09-06. This test used to assert that BOTH median and MADN survive the
    /// downsample within 2%. That is FALSE on real data: measured on a 6236x4159 M51 master,
    /// downsampling loses 48% of the MADN at the shipped 3x factor (69% at the old 6x) because
    /// averaging is exactly what destroys pixel noise. The assertion passed only because
    /// `starField` is a smooth synthetic fixture with an unrepresentatively low MADN/median
    /// ratio — a test that agreed with an unrepresentative image rather than with the product.
    ///
    /// What the preview actually needs is not "the statistics are preserved" but "the RENDERED
    /// RESULT matches", and those differ: `shadow = median - 2.8 * MADN`, and on real astro data
    /// MADN is 10-130x smaller than the median, so even a 50% MADN loss barely moves the shadow
    /// point. Measured end-to-end on the same real master: 0.10/255 on a 16-sub stack, 1.76/255
    /// on a single (noisiest) sub. So this now asserts the median (which IS preserved) and the
    /// resulting 8-bit output, over a NOISY image where the old assertion would have failed.
    func testDownsamplePreservesTheRenderedResultNotTheRawStatistics() {
        // A fixture whose MADN is NOISE-dominated, like a real sub. Starting from starField was
        // wrong: its 0.02 background GRADIENT dominates MADN and survives averaging exactly, so
        // MADN came out bit-identical and the test proved nothing. Real single-sub M51 data
        // measures median 0.0104 with MADN 0.000905 — a ratio of 0.087 — so that is what this
        // reproduces: flat background, noise at that ratio, a few stars for structure.
        // MUST exceed previewLongEdge or downsampled() returns self and the test measures
        // nothing — which is exactly what happened at 2400x1800 once the cap was raised to 2400.
        let w = 4800, h = 3600, plane = w * h
        var px = [Float](repeating: 0, count: plane)
        var seed: UInt64 = 0x5EED
        for i in 0..<plane {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u = Float((seed >> 33) % 20_001) / 20_000 - 0.5     // uniform -0.5...0.5
            px[i] = 0.0104 + u * 0.0031                              // MADN ~= 0.0009, ratio ~0.087
        }
        for (sx, sy, amp) in [(1200, 1000, Float(0.6)), (3000, 2200, 0.4), (4000, 1400, 0.5)] {
            for dy in -8...8 {
                for dx in -8...8 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    px[y * w + x] += amp * exp(-Float(dx * dx + dy * dy) / 12.0)
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let proxy = img.downsampled(maxLongEdge: SessionPipeline.previewLongEdge)
        XCTAssertLessThanOrEqual(max(proxy.width, proxy.height), SessionPipeline.previewLongEdge)

        let (mFull, dFull) = PreviewTestSupport.medianAndMADN(img)
        let (mProxy, dProxy) = PreviewTestSupport.medianAndMADN(proxy)

        // The median IS preserved, and it is the dominant term in the shadow point.
        XCTAssertEqual(mProxy, mFull, accuracy: abs(mFull) * 0.02,
                       "median must survive the downsample — it dominates shadow = median - 2.8*MADN")

        // MADN is NOT preserved, deliberately asserted so nobody "fixes" this back:
        XCTAssertLessThan(dProxy, dFull,
                          "averaging destroys pixel noise, so proxy MADN is EXPECTED to fall — the "
                          + "old assertion that it survives within 2% was true only of a smooth fixture")

        // What must hold is the rendered result. Compare the 8-bit shadow/midtone output the two
        // derived transforms produce across the tonal range the operator actually sees.
        func out8(_ v: Double, _ med: Double, _ madn: Double) -> Double {
            let shadow = min(max(med - 2.8 * madn, 0), 1)
            let x = min(max((v - shadow) / max(1 - shadow, 1e-9), 0), 1)
            let m = 0.25
            return 255 * ((m - 1) * x) / (((2 * m - 1) * x) - m)
        }
        var worst = 0.0
        for step in 0...12 {
            let v = mFull * (0.5 + 3.5 * Double(step) / 12)
            worst = max(worst, abs(out8(v, mFull, dFull) - out8(v, mProxy, dProxy)))
        }
        XCTAssertLessThan(worst, 4.0,
                          "the preview's derived stretch must render within ~4/255 of the broadcast's; "
                          + "measured 0.10/255 on a real 16-sub master and 1.76/255 on a single sub")
    }

    /// Sentinel against the planar/interleaved confusion that produced the earlier draft of
    /// this plan: give each channel a distinct constant and prove the planes stay separate and
    /// keep their values through the downsample. Interleaved indexing anywhere in the chain
    /// smears the three constants together and this fails.
    func testDownsampleKeepsColourPlanesSeparate() {
        // MUST exceed previewLongEdge or downsampled() returns self and the test measures
        // nothing — which is exactly what happened at 2400x1800 once the cap was raised to 2400.
        let w = 4800, h = 3600, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane { px[i] = 0.10; px[plane + i] = 0.50; px[2 * plane + i] = 0.90 }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)

        let out = img.downsampled(maxLongEdge: SessionPipeline.previewLongEdge)
        let outPlane = out.width * out.height
        XCTAssertEqual(out.channels, 3)
        // Accumulate in Double, not Float: a naive Float accumulator summing ~1.08M values
        // near 0.1-0.9 loses precision well before the loop ends (the running sum's magnitude
        // outgrows float32's ~7-digit resolution long before all terms are added), which
        // produces a false ~1% "drift" that looks exactly like a downsample bug but isn't —
        // confirmed by cross-checking with `AstroImage.computeStats`, which accumulates the
        // same way (`AstroImage.swift:88`) for the same reason.
        for (c, expected) in [(0, 0.10), (1, 0.50), (2, 0.90)] {
            var sum = 0.0
            for i in 0..<outPlane { sum += Double(out.pixels[c * outPlane + i]) }
            let mean = sum / Double(outPlane)
            XCTAssertEqual(mean, expected, accuracy: 0.001,
                           "channel \(c) must keep its own value — planar layout, not interleaved")
        }
    }
}
