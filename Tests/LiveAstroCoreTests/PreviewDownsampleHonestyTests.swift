import XCTest
@testable import LiveAstroCore

/// The staged preview renders from a downsample. `AutoStretch` derives its transform from the
/// image's OWN median and MADN (`AutoStretch.swift:47-57`), so if downsampling moved those
/// statistics the preview would show a different stretch than the broadcast — a preview that
/// lies is worse than no preview. `AstroImageDownsampleTests` already covers the mechanics of
/// the downsample; this covers the property the preview design rests on, which nothing did.
final class PreviewDownsampleHonestyTests: XCTestCase {

    func testDownsamplePreservesTheStatisticsAutoStretchDerives() {
        let full = PreviewTestSupport.starField()
        let proxy = full.downsampled(maxLongEdge: SessionPipeline.previewLongEdge)
        XCTAssertLessThanOrEqual(max(proxy.width, proxy.height), SessionPipeline.previewLongEdge)

        let (mFull, dFull) = PreviewTestSupport.medianAndMADN(full)
        let (mProxy, dProxy) = PreviewTestSupport.medianAndMADN(proxy)
        XCTAssertEqual(mProxy, mFull, accuracy: abs(mFull) * 0.02,
                       "median must survive the preview downsample within 2% — the stretch is derived from it")
        XCTAssertEqual(dProxy, dFull, accuracy: abs(dFull) * 0.02,
                       "MADN must survive the preview downsample within 2% — it sets the stretch slope")
    }

    /// Sentinel against the planar/interleaved confusion that produced the earlier draft of
    /// this plan: give each channel a distinct constant and prove the planes stay separate and
    /// keep their values through the downsample. Interleaved indexing anywhere in the chain
    /// smears the three constants together and this fails.
    func testDownsampleKeepsColourPlanesSeparate() {
        let w = 2400, h = 1800, plane = w * h
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
