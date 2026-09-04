import XCTest
import CryptoKit
@testable import LiveAstroCore

/// Helpers shared by the preview/staging tests.
///
/// `AstroImage` is PLANAR (channel-major) — `AstroImage.swift:16`, and see `Denoiser.swift:78`
/// indexing `sane[i], sane[plane + i], sane[2 * plane + i]`. Index as
/// `c * plane + y * width + x`; interleaved indexing silently scrambles colour AND would make
/// these helpers agree with a broken implementation, so the tests would pass while the code is
/// wrong.
enum PreviewTestSupport {

    /// Non-uniform planar star field with a gradient. A CONSTANT image would let every
    /// statistic survive any transformation, making the honesty tests vacuous.
    static func starField(w: Int = 2400, h: Int = 1800, channels: Int = 3) -> AstroImage {
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * channels)
        for c in 0..<channels {
            for y in 0..<h {
                for x in 0..<w {
                    let bg = 0.04 + 0.02 * Float(x) / Float(w)
                    let grain = Float((x &* 7 &+ y &* 13) % 11) * 0.0008
                    px[c * plane + y * w + x] = bg + grain + Float(c) * 0.005
                }
            }
        }
        for (sx, sy, amp) in [(520, 430, Float(0.8)), (1400, 1100, 0.5), (1900, 600, 0.65)] {
            for dy in -8...8 {
                for dx in -8...8 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    let g = amp * exp(-Float(dx * dx + dy * dy) / 12.0)
                    for c in 0..<channels { px[c * plane + y * w + x] += g }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: channels, pixels: px, sourceIsLinear: true)
    }

    /// Planar luminance -> (median, MADN): the two values AutoStretch derives its transform from.
    static func medianAndMADN(_ image: AstroImage) -> (Double, Double) {
        let plane = image.width * image.height
        var lum = [Float](repeating: 0, count: plane)
        for c in 0..<image.channels {
            for i in 0..<plane { lum[i] += image.pixels[c * plane + i] }
        }
        let inv = Float(image.channels)
        for i in 0..<plane { lum[i] /= inv }
        lum.sort()
        let med = Double(lum[plane / 2])
        var dev = lum.map { abs(Double($0) - med) }
        dev.sort()
        return (med, dev[plane / 2] * 1.4826)
    }

    static func sha256(_ cg: CGImage) -> String {
        guard let data = cg.dataProvider?.data as Data? else { return "no-data" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SessionPipeline {
    /// Test seam: a minimal pipeline usable for render-path tests. `nativeSource` is
    /// NON-OPTIONAL on the native init (`SessionPipeline.swift:797`), so pass an empty stub
    /// source rather than nil — `StubLiveSource(sequence: [])` never yields a frame, so nothing
    /// runs.
    ///
    /// Lives here (test target), not in `SessionPipeline.swift` (production target), because
    /// `StubLiveSource` is a test-only type and production code cannot see test-target types.
    static func forRenderTest() -> SessionPipeline {
        SessionPipeline(nativeSource: StubLiveSource(sequence: []), engine: StackEngine(),
                        profile: SessionProfile(targetName: "RenderTest", telescope: "T", camera: "C",
                                                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                                subExposureSeconds: 1, notes: ""),
                        rootDirectory: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
}
