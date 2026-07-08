import XCTest
@testable import LiveAstroCore

final class StallDetectorTests: XCTestCase {

    func testThresholdIsMaxOfScaledAndFloor() {
        XCTAssertEqual(StallDetector(subExposureSeconds: 20).threshold, 90, accuracy: 1e-9) // 3*20=60 < 90
        XCTAssertEqual(StallDetector(subExposureSeconds: 60).threshold, 180, accuracy: 1e-9) // 3*60=180 > 90
    }

    func testNotStalledBeforeThreshold() {
        var d = StallDetector(subExposureSeconds: 60) // threshold 180
        d.recordUpdate(at: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 1000 + 179)))
        XCTAssertTrue(d.isStalled(at: Date(timeIntervalSince1970: 1000 + 181)))
    }

    func testRecordResetsClock() {
        var d = StallDetector(subExposureSeconds: 60)
        d.recordUpdate(at: Date(timeIntervalSince1970: 1000))
        d.recordUpdate(at: Date(timeIntervalSince1970: 1170))   // fresh update
        XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 1170 + 179)))
    }

    func testStalledWhenNoUpdateEver() {
        let d = StallDetector(subExposureSeconds: 60)
        XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 0)))  // no baseline yet → not stalled
    }
}
