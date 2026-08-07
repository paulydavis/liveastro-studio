import XCTest
@testable import LiveAstroCore

final class SessionCompletionDriverTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    private func d(_ s: String) -> Date { let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; return f.date(from: s)! }
    private let s = CompletionSettings(idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
                                       plannedStopEnabled: false, plannedStopHour: 3, plannedStopMinute: 0)

    func testSafeguardFiresOncePerIdleEpisode() {
        var drv = SessionCompletionDriver()
        let t0 = d("2026-08-07T22:00:00-04:00")
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:16:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .safeguard)
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:20:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .none)
    }
    func testResumedFrameReArmsSafeguard() {
        var drv = SessionCompletionDriver()
        let t0 = d("2026-08-07T22:00:00-04:00")
        _ = drv.step(now: d("2026-08-07T22:16:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal) // fires
        let t1 = d("2026-08-07T22:18:00-04:00")   // Seestar resumed
        _ = drv.step(now: d("2026-08-07T22:18:05-04:00"), lastAcceptedFrame: t1, settings: s, calendar: cal) // re-arm, not elapsed
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:34:00-04:00"), lastAcceptedFrame: t1, settings: s, calendar: cal), .safeguard) // fires again
    }
    func testPlannedStopFiresOnce() {
        var drv = SessionCompletionDriver()
        let s2 = CompletionSettings(idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
                                    plannedStopEnabled: true, plannedStopHour: 3, plannedStopMinute: 0)
        XCTAssertEqual(drv.step(now: d("2026-08-08T03:01:00-04:00"), lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: s2, calendar: cal), .endSession)
        XCTAssertEqual(drv.step(now: d("2026-08-08T03:05:00-04:00"), lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: s2, calendar: cal), .none)
    }
    func testClearSafeguardForRetryRefires() {
        var drv = SessionCompletionDriver()
        let t0 = d("2026-08-07T22:00:00-04:00")
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:16:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .safeguard)
        drv.clearSafeguardForRetry()
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:20:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .safeguard)
    }
}
