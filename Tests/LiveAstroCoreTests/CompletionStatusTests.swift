import XCTest
@testable import LiveAstroCore

final class CompletionStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    // Deterministic clock formatter stub so tests don't depend on locale/timezone.
    private let clock: (Date) -> String = { _ in "3:00 AM" }

    func testNothingEnabledReturnsNil() {
        XCTAssertNil(CompletionStatus.line(
            plannedStopEnabled: false, plannedDeadline: nil,
            idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock))
    }

    func testIdleShownOnlyInNativeMode() {
        // Native + idle → shown.
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: false, plannedDeadline: nil,
            idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock), "idle-safe 15 min")
        // External + idle → HIDDEN (the P3 follow-on bug: safeguard is native-only,
        // so the Live tab must not advertise it in external-stacker mode).
        XCTAssertNil(CompletionStatus.line(
            plannedStopEnabled: false, plannedDeadline: nil,
            idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
            isNativeStacking: false, now: now, clockString: clock))
    }

    func testPlannedShownInAnyMode() {
        // Planned stop works in any mode (endSession is mode-agnostic).
        let deadline = now.addingTimeInterval(2 * 3600)   // >1h → clock time
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
            isNativeStacking: false, now: now, clockString: clock),
            "Auto-stop 3:00 AM")   // planned shown, idle omitted (external)
    }

    func testPlannedCountdownUnderOneHour() {
        let deadline = now.addingTimeInterval(24 * 60 + 20)   // ~24 min
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock),
            "Auto-stop in 24 min")
    }

    func testCountdownFloorsNotRounds() {
        // 3599s remaining → 59 min (floor), never "60 min" inside the <1h branch.
        let deadline = now.addingTimeInterval(3599)
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock),
            "Auto-stop in 59 min")
    }

    func testExactlyOneHourShowsClock() {
        // 3600s remaining is the branch boundary: >= 3600 → clock time, not countdown.
        let deadline = now.addingTimeInterval(3600)
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock),
            "Auto-stop 3:00 AM")
    }

    func testNegativeRemainingClampsToZero() {
        // Deadline already passed (tick lag before endSession fires) → "0 min", not negative.
        let deadline = now.addingTimeInterval(-120)
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock),
            "Auto-stop in 0 min")
    }

    func testBothNativeJoined() {
        let deadline = now.addingTimeInterval(3 * 3600)
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: deadline,
            idleSafeguardEnabled: true, idleSafeguardMinutes: 20,
            isNativeStacking: true, now: now, clockString: clock),
            "Auto-stop 3:00 AM · idle-safe 20 min")
    }

    func testPlannedEnabledButNilDeadlineOmitsPlanned() {
        // Defensive: planned enabled but no deadline supplied → planned omitted;
        // native idle still shows.
        XCTAssertEqual(CompletionStatus.line(
            plannedStopEnabled: true, plannedDeadline: nil,
            idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
            isNativeStacking: true, now: now, clockString: clock), "idle-safe 15 min")
    }
}
