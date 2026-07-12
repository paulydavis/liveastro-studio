import XCTest
@testable import LiveAstroCore

final class IntegrationFormatDerivedTests: XCTestCase {
    func testFrameCountDerivedFromSeconds() {
        // 27 accepted × 30s: frame count must read 27 (from seconds), never the
        // session-total (e.g. 34) that a post-reseed index would carry.
        let s = IntegrationFormat.caption(seconds: 27 * 30, subSeconds: 30)
        XCTAssertTrue(s.contains("27 × 30s"), s)
    }
    func testZeroSubSecondsNoCrash() {
        // Guard: subSeconds 0 → 0 frames, no divide-by-zero / trap.
        let s = IntegrationFormat.caption(seconds: 0, subSeconds: 0)
        XCTAssertTrue(s.contains("0 ×"), s)
    }
    func testRoundsToNearestFrame() {
        // 26.6 × 30 ≈ 798s → 798/30 = 26.6 → rounds to 27.
        let s = IntegrationFormat.caption(seconds: 798, subSeconds: 30)
        XCTAssertTrue(s.contains("27 × 30s"), s)
    }
}
