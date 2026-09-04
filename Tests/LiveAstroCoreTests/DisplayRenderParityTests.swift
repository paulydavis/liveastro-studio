import XCTest
@testable import LiveAstroCore

/// The render path behind this test produces the broadcast, snapshots, latest.png and
/// master.fit. A regression here is SILENT — it lands in recorded data, not in a crash — so
/// the committed-path output is pinned by hash across the refactor that parameterises it.
final class DisplayRenderParityTests: XCTestCase {

    /// The adjustment set under test exercises every stage: black point, midtone, saturation,
    /// DBE (with both its parameters) and denoise.
    static var pinnedAdjustments: DisplayAdjustments {
        var a = DisplayAdjustments.neutral
        a.blackPoint = 0.02
        a.midtoneStrength = 0.35
        a.saturation = 1.4
        a.backgroundExtraction = true
        a.bgScale = 8
        a.bgSmoothest = 1.5
        a.denoiseStrength = 0.3
        return a
    }

    func testCommittedRenderIsUnchangedByParameterisation() throws {
        let pipeline = SessionPipeline.forRenderTest()
        let cg = try pipeline.renderForTest(PreviewTestSupport.starField(w: 320, h: 240),
                                            adjustments: Self.pinnedAdjustments)
        XCTAssertEqual(PreviewTestSupport.sha256(cg),
                       "5c1b48e036f61951534938b37c37eda3b7ad9cdc19911a52170e838c468abafb",
                       "the committed render path must be byte-identical across the refactor")
    }
}
