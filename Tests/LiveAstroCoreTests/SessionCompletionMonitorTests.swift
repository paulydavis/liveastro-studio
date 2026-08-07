import XCTest
@testable import LiveAstroCore

final class SessionCompletionMonitorTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    private func d(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; return f.date(from: s)!
    }
    private func settings(idle: Bool = true, mins: Int = 15, planned: Bool = false, h: Int = 3, m: Int = 0) -> CompletionSettings {
        CompletionSettings(idleSafeguardEnabled: idle, idleSafeguardMinutes: mins,
                           plannedStopEnabled: planned, plannedStopHour: h, plannedStopMinute: m)
    }

    // --- planned stop deadline (next occurrence, midnight crossing) ---
    func testPlannedDeadlineLaterToday() {
        // 22:00, stop 23:30 → same day 23:30
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T22:00:00-04:00"), hour: 23, minute: 30, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-07T23:30:00-04:00"))
    }
    func testPlannedDeadlineCrossesMidnight() {
        // 23:00, stop 03:00 → NEXT day 03:00
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T23:00:00-04:00"), hour: 3, minute: 0, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-08T03:00:00-04:00"))
    }
    func testPlannedDeadlineTimeAlreadyPassedTodayRollsToTomorrow() {
        // 04:00, stop 03:00 → tomorrow 03:00
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T04:00:00-04:00"), hour: 3, minute: 0, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-08T03:00:00-04:00"))
    }

    // --- idle ---
    func testIdleNotElapsed() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:10:00-04:00"), sessionStart: d("2026-08-07T21:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)   // only 10 min < 15
    }
    func testIdleElapsedFiresSafeguard() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:16:00-04:00"), sessionStart: d("2026-08-07T21:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .safeguard)
    }
    func testIdleElapsedButAlreadyFiredStaysNone() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:30:00-04:00"), sessionStart: d("2026-08-07T21:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: true, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)   // one safeguard per idle episode
    }
    func testIdleDisabledNeverFires() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T23:00:00-04:00"), sessionStart: d("2026-08-07T21:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(idle: false),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }
    func testNoFramesYetUsesNoIdle() {
        // lastAcceptedFrame nil (session just started, no accepts) → no idle safeguard
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:16:00-04:00"), sessionStart: d("2026-08-07T21:00:00-04:00"),
            lastAcceptedFrame: nil, settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }

    // --- planned stop ---
    func testPlannedStopBeforeDeadline() {
        // session started 23:00, stop 03:00, now 02:59 → not yet (deadline is next-morning 03:00)
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T02:59:00-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }
    func testPlannedStopAtDeadlineFires() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:00:05-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }
    func testPlannedStopAlreadyFiredStaysNone() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:05:00-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: true, calendar: cal)
        XCTAssertEqual(a, .none)
    }

    // --- priority: both due → endSession wins ---
    func testBothDueEndSessionWins() {
        // idle elapsed AND past 03:00 stop
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:20:00-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: settings(mins: 15, planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }

    // --- regression: evening-start planned stop must NOT fire immediately (Critical #1) ---
    func testPlannedStopEveningStartDoesNotFireImmediately() {
        // Start 23:00, stop 03:00, now 23:00:30 (first tick) → next occurrence is next-morning
        // 03:00, still ~4 h away. The old inline "past today's 03:00" logic fired here.
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T23:00:30-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T23:00:10-04:00"), settings: settings(idle: false, planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }
    func testPlannedStopEveningStartFiresNextMorning() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:00:05-04:00"), sessionStart: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(idle: false, planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }
    func testPlannedStopLaterSameEvening() {
        // Start 22:00, stop 23:30, now 23:31 → same-evening deadline reached
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T23:31:00-04:00"), sessionStart: d("2026-08-07T22:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T23:00:00-04:00"), settings: settings(idle: false, planned: true, h: 23, m: 30),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }
}
