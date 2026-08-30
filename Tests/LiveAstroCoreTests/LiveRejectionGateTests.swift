import XCTest
@testable import LiveAstroCore

/// Table test for `LiveRejectionGate.reason` (Task 11 Step 1) — pins both each individual branch
/// and the precedence order between them.
final class LiveRejectionGateTests: XCTestCase {

    func testActiveWhenLocalEnoughSubsAndOn() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 12,
                                               minSubs: 5, reseeding: false, enabled: true)
        XCTAssertEqual(status, .active(subs: 12))
    }

    func testOffNetworkSource() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: false, subCount: 12,
                                               minSubs: 5, reseeding: false, enabled: true)
        XCTAssertEqual(status, .off(reason: "network source"))
    }

    func testOffTooFewSubs() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 3,
                                               minSubs: 5, reseeding: false, enabled: true)
        XCTAssertEqual(status, .off(reason: "need ≥ 5 subs"))
    }

    func testOffTooFewSubsInterpolatesRealMinSubs() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 1,
                                               minSubs: 11, reseeding: false, enabled: true)
        XCTAssertEqual(status, .off(reason: "need ≥ 11 subs"))
    }

    func testOffReseeding() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 12,
                                               minSubs: 5, reseeding: true, enabled: true)
        XCTAssertEqual(status, .off(reason: "reseeding"))
    }

    func testOffTurnedOff() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 12,
                                               minSubs: 5, reseeding: false, enabled: false)
        XCTAssertEqual(status, .off(reason: "turned off"))
    }

    // MARK: - Precedence

    /// Turned-off beats every other reason, even when several conditions are simultaneously
    /// "bad" (network source, reseeding, too few subs all also true here).
    func testPrecedenceTurnedOffBeatsEverythingElse() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: false, subCount: 0,
                                               minSubs: 5, reseeding: true, enabled: false)
        XCTAssertEqual(status, .off(reason: "turned off"))
    }

    /// Network source beats reseeding and too-few-subs when the toggle is on.
    func testPrecedenceNetworkSourceBeatsReseedingAndTooFewSubs() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: false, subCount: 0,
                                               minSubs: 5, reseeding: true, enabled: true)
        XCTAssertEqual(status, .off(reason: "network source"))
    }

    /// Reseeding beats too-few-subs when the toggle is on and the source is local.
    func testPrecedenceReseedingBeatsTooFewSubs() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 0,
                                               minSubs: 5, reseeding: true, enabled: true)
        XCTAssertEqual(status, .off(reason: "reseeding"))
    }
}
