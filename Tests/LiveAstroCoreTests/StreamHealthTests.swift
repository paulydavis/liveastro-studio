import XCTest
@testable import LiveAstroCore

final class StreamHealthTests: XCTestCase {
    func testParseFullResponse() {
        let dict: [String: Any] = [
            "outputActive": true, "outputDuration": 754000,       // ms
            "outputSkippedFrames": 3, "outputTotalFrames": 1500,
            "outputCongestion": 0.2
        ]
        let h = StreamHealth.parse(dict)!
        XCTAssertTrue(h.active)
        XCTAssertEqual(h.durationSeconds, 754.0, accuracy: 1e-6)
        XCTAssertEqual(h.skippedFrames, 3)
        XCTAssertEqual(h.totalFrames, 1500)
        XCTAssertEqual(h.congestion, 0.2, accuracy: 1e-6)
        XCTAssertEqual(h.droppedFraction, 3.0 / 1500.0, accuracy: 1e-9)
    }

    func testMissingActiveIsNil() {
        XCTAssertNil(StreamHealth.parse(["outputDuration": 1000]))   // no outputActive → nil
    }

    func testCongestionClampedAndDefaults() {
        let h = StreamHealth.parse(["outputActive": false, "outputCongestion": 1.7])!
        XCTAssertFalse(h.active)
        XCTAssertEqual(h.congestion, 1.0, accuracy: 1e-6)   // clamped to [0,1]
        XCTAssertEqual(h.durationSeconds, 0)                // absent numeric → 0
        XCTAssertEqual(h.totalFrames, 0)
        XCTAssertEqual(h.droppedFraction, 0)                // total 0 → 0, no divide-by-zero
    }

    func testNumericTypeFlexibility() {
        // OBS-ws numbers may decode as Int or Double; parse must accept both.
        let h = StreamHealth.parse([
            "outputActive": true, "outputDuration": 500.0,
            "outputSkippedFrames": 0, "outputTotalFrames": 100, "outputCongestion": 0
        ])!
        XCTAssertEqual(h.durationSeconds, 0.5, accuracy: 1e-6)
    }
}
