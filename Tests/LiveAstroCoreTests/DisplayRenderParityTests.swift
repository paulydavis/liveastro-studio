import XCTest
@testable import LiveAstroCore

/// The render path behind this test produces the broadcast, snapshots, latest.png and
/// master.fit. A regression here is SILENT — it lands in recorded data, not in a crash — so
/// the committed-path output is pinned by hash across the refactor that parameterises it.
final class DisplayRenderParityTests: XCTestCase {

    /// The adjustment set under test exercises every stage: midtone, saturation, DBE (with both
    /// its parameters) and denoise.
    ///
    /// Black point is deliberately 0. It used to be 0.02, but that value was inert — the old
    /// implementation renormalised it away (see `AutoStretch.stretch`), so it pinned nothing while
    /// looking like it did. Fixing black point necessarily moves any hash taken at a non-zero
    /// value, which would make this guard re-baseline on an intended change. At 0 the hash is
    /// stable across that fix — verified byte-identical against the pre-fix implementation — and
    /// this test stays a pure guard on every OTHER stage. Black point's own behaviour is pinned by
    /// `AutoStretchAdjustmentsTests.testBlackPointDarkensTheRenderedBackground`.
    static var pinnedAdjustments: DisplayAdjustments {
        var a = DisplayAdjustments.neutral
        a.blackPoint = 0
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
                       "61cbd7ad37ca0ef6d0bfae7d62da5bd9cc432fc4dc67d86dd231ff21bbcbeda6",
                       "the committed render path must be byte-identical across the refactor")
    }
}
