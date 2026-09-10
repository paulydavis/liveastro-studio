import XCTest
@testable import LiveAstroCore

/// MEASUREMENT, not a gate. Answers one question before any caching work is written: how much of
/// a committed render is DBE, at the resolution the broadcast actually renders?
///
/// Context: committed renders were measured landing one per frame at 87 SECONDS on a real 26 MP
/// session, which made an Apply invisible for minutes. Caching the pre-stretch DBE result is only
/// worth building if DBE is in fact the dominant term — and only helps when the source and the DBE
/// parameters are unchanged, which is the downstream-edit case (black point, stretch, saturation,
/// denoise) and NOT new frames, new clean masters, or DBE edits.
///
/// Gated: needs a real master. Run with
///   LAS_RUN_RENDER_COST=1 swift test -c release --filter CommittedRenderCostMeasurementTests
/// Release matters: these costs are several times higher in debug and would misinform the design.
final class CommittedRenderCostMeasurementTests: XCTestCase {

    private func elapsed(_ label: String, _ body: () -> Void) -> Double {
        let t0 = Date()
        body()
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "RENDER-COST  %-28s %8.1f ms", (label as NSString).utf8String!, ms))
        return ms
    }

    func testCommittedRenderStageCosts() throws {
        guard ProcessInfo.processInfo.environment["LAS_RUN_RENDER_COST"] != nil else {
            throw XCTSkip("set LAS_RUN_RENDER_COST=1 (needs a real master; run -c release)")
        }
        let master = URL(fileURLWithPath: (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/LiveAstro/2026-09-02-m51-2/master.fit"))
        guard FileManager.default.fileExists(atPath: master.path) else {
            throw XCTSkip("real master not present at \(master.path)")
        }

        let full = try ImageLoader.load(url: master, expectedIdentity: nil)
        print("RENDER-COST  source \(full.width)x\(full.height)x\(full.channels)")

        // CORRECTION: 2560 is the IMPORT path (renderSnapshot). NATIVE LIVE renders the cropped
        // mean at FULL RESOLUTION and resolves the broadcast with downsampleLongEdge: nil, and
        // stores displayOnline with cap: nil so Apply's own render is full-res too. Measuring at
        // 2560 described a path the live session never used. Both are measured here.
        var linear = full
        _ = elapsed("downsample to 2560 (import path)") {
            linear = full.downsampled(maxLongEdge: SnapshotRecorder.maxSnapshotLongEdge)
        }
        print("RENDER-COST  import-path render size \(linear.width)x\(linear.height)")

        // Paul's actual settings from the live session (sessionSettings.v1).
        let bgScale = 2.9611440772720226, bgSmoothest = 0.5
        let denoise = 0.7257130587748345, blackPoint = 0.24986757297550768

        var flattened = linear
        let dbe = elapsed("DBE flattenMultiscale") {
            flattened = BackgroundExtraction.flattenMultiscale(linear, scale: bgScale,
                                                               smoothest: bgSmoothest)
        }
        var balanced = flattened
        let neutralize = elapsed("neutralizeBackground") {
            balanced = AutoStretch.neutralizeBackground(flattened)
        }
        var stretched = balanced
        let stretch = elapsed("AutoStretch.stretch") {
            stretched = AutoStretch.stretch(balanced, blackPoint: blackPoint, midtoneStrength: 0)
        }
        var denoised = stretched
        let denoiseMs = elapsed("Denoiser.apply") {
            denoised = Denoiser.apply(stretched, strength: Float(denoise))
        }
        var saturated = denoised
        let saturation = elapsed("applySaturation") {
            saturated = AutoStretch.applySaturation(denoised, 1.0)
        }
        let pack = elapsed("makeCGImage") {
            _ = AutoStretch.makeCGImage(saturated)
        }

        let total = dbe + neutralize + stretch + denoiseMs + saturation + pack
        print(String(format: "RENDER-COST  IMPORT-PATH TOTAL %.1f ms — DBE is %.1f%% of it", total, 100 * dbe / total))

        // NATIVE LIVE: full resolution, and it renders TWICE per frame (preview from the online
        // mean, broadcast from the resolved master), plus Apply's own render is also full-res.
        print("RENDER-COST  --- NATIVE LIVE, full resolution \(full.width)x\(full.height) ---")
        var f1 = full
        let dbeFull = elapsed("DBE flattenMultiscale (full)") {
            f1 = BackgroundExtraction.flattenMultiscale(full, scale: bgScale, smoothest: bgSmoothest)
        }
        var b1 = f1
        let neutFull = elapsed("neutralizeBackground (full)") { b1 = AutoStretch.neutralizeBackground(f1) }
        var s1 = b1
        let stretchFull = elapsed("AutoStretch.stretch (full)") {
            s1 = AutoStretch.stretch(b1, blackPoint: blackPoint, midtoneStrength: 0)
        }
        var d1 = s1
        let denoiseFull = elapsed("Denoiser.apply (full)") {
            d1 = Denoiser.apply(s1, strength: Float(denoise))
        }
        let packFull = elapsed("makeCGImage (full)") { _ = AutoStretch.makeCGImage(d1) }
        let oneFull = dbeFull + neutFull + stretchFull + denoiseFull + packFull
        print(String(format: "RENDER-COST  ONE full-res render %.1f ms (DBE %.1f%%)",
                     oneFull, 100 * dbeFull / oneFull))
        print(String(format: "RENDER-COST  native live does TWO per frame -> %.1f ms of render per frame",
                     2 * oneFull))
        print(String(format: "RENDER-COST  ratio full-res : 2560 = %.1fx", oneFull / total))
        // Channel-count comparison: the live harness rendered 26 MP MONO with DBE on in ~214 ms,
        // against 14 s for DBE on this 3-channel master. 3x the data cannot explain 65x.
        let mono = AstroImage(width: full.width, height: full.height, channels: 1,
                              pixels: Array(full.pixels[0..<(full.width * full.height)]),
                              sourceIsLinear: true)
        _ = elapsed("DBE on 1-channel 26MP") {
            _ = BackgroundExtraction.flattenMultiscale(mono, scale: bgScale, smoothest: bgSmoothest)
        }
        _ = elapsed("DBE on 3-channel 26MP (again)") {
            _ = BackgroundExtraction.flattenMultiscale(full, scale: bgScale, smoothest: bgSmoothest)
        }
        XCTAssertGreaterThan(total, 0)
    }
}
