import XCTest
@testable import LiveAstroCore

final class FrameSelectorTests: XCTestCase {

    func testSmallCountReturnsAll() {
        XCTAssertEqual(FrameSelector.logSpacedIndices(count: 5, maxKeyframes: 10), [0, 1, 2, 3, 4])
    }

    func testAlwaysIncludesFirstAndLast() {
        let idx = FrameSelector.logSpacedIndices(count: 1000, maxKeyframes: 30)
        XCTAssertEqual(idx.first, 0)
        XCTAssertEqual(idx.last, 999)
        XCTAssertLessThanOrEqual(idx.count, 31)
    }

    func testEarlyBias() {
        let idx = FrameSelector.logSpacedIndices(count: 1000, maxKeyframes: 30)
        let firstHalf = idx.filter { $0 < 500 }.count
        let secondHalf = idx.filter { $0 >= 500 }.count
        XCTAssertGreaterThan(firstHalf, secondHalf,
                             "log spacing must sample the early session more densely")
    }

    func testSortedUnique() {
        let idx = FrameSelector.logSpacedIndices(count: 100, maxKeyframes: 50)
        XCTAssertEqual(idx, Array(Set(idx)).sorted())
    }

    func testDedupeDropsNearIdenticalButKeepsEnds() {
        // difference: everything identical except index 0 vs anything.
        let picked = FrameSelector.select(count: 100, maxKeyframes: 20,
                                          difference: { a, b in (a == 0 || b == 0) ? 1.0 : 0.0 })
        XCTAssertEqual(picked.first, 0)
        XCTAssertEqual(picked.last, 99, "final frame survives even when visually identical")
        XCTAssertLessThanOrEqual(picked.count, 3, "middle duplicates removed")
    }

    func testThumbnailDifference() {
        let a = AstroImage(width: 128, height: 128, channels: 1,
                           pixels: [Float](repeating: 0.2, count: 128 * 128), sourceIsLinear: false)
        let b = AstroImage(width: 128, height: 128, channels: 1,
                           pixels: [Float](repeating: 0.8, count: 128 * 128), sourceIsLinear: false)
        XCTAssertEqual(FrameSelector.thumbnailDifference(a, a), 0, accuracy: 1e-6)
        XCTAssertEqual(FrameSelector.thumbnailDifference(a, b), 0.6, accuracy: 0.01)
    }

    func testQualityGateSkipsCloudSpike() {
        // Slowly drifting background with a cloud spike at index 5 (0.02 → 0.06 = +200%)
        let medians = [0.020, 0.020, 0.019, 0.019, 0.018, 0.060, 0.018, 0.018, 0.017, 0.017]
        let kept = FrameSelector.qualityGate(medians: medians)
        XCTAssertFalse(kept.contains(5))
        XCTAssertEqual(kept.first, 0)
        XCTAssertEqual(kept.last, medians.count - 1)
        XCTAssertEqual(kept.count, medians.count - 1)
    }

    func testQualityGateCleanSequenceUntouched() {
        // Normal stack: background drifts slowly downward as noise integrates out
        let medians = (0..<20).map { 0.030 - Double($0) * 0.0005 }
        XCTAssertEqual(FrameSelector.qualityGate(medians: medians), Array(0..<20))
    }

    func testQualityGateAlwaysKeepsFirstAndLast() {
        // Final frame is itself a spike — kept anyway (it's the session's payoff frame)
        let medians = [0.020, 0.020, 0.020, 0.020, 0.020, 0.080]
        let kept = FrameSelector.qualityGate(medians: medians)
        XCTAssertEqual(kept.last, 5)
    }

    func testQualityGateShortSequences() {
        XCTAssertEqual(FrameSelector.qualityGate(medians: []), [])
        XCTAssertEqual(FrameSelector.qualityGate(medians: [0.5]), [0])
        XCTAssertEqual(FrameSelector.qualityGate(medians: [0.5, 5.0]), [0, 1])
    }

    func testQualityGateNearZeroBaselineKeepsAll() {
        // All-dark session: baseline below the meaningful-median floor must keep
        // every frame rather than divide by ~0 and reject everything.
        let medians = [Double](repeating: 1e-15, count: 8)
        XCTAssertEqual(FrameSelector.qualityGate(medians: medians), Array(0..<8))
    }

    func testQualityGateRecoversAfterCloudBand() {
        // Multi-frame cloud band: indices 4...6 all spiked; baseline must not absorb them
        let medians = [0.020, 0.020, 0.020, 0.020, 0.055, 0.060, 0.058, 0.020, 0.020, 0.020]
        let kept = FrameSelector.qualityGate(medians: medians)
        XCTAssertEqual(kept, [0, 1, 2, 3, 7, 8, 9])
    }
}
