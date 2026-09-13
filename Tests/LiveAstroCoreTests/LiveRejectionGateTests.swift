import XCTest
@testable import LiveAstroCore

/// Table test for `LiveRejectionGate.reason` (Task 11 Step 1) — pins both each individual branch
/// and the precedence order between them.
final class LiveRejectionGateTests: XCTestCase {

    /// `.active` now means "a clean master EXISTS and is being served", so it reports the
    /// PUBLISHED survivor count — which lags the registered count while a pass is in flight.
    func testActiveWhenLocalEnoughSubsOnAndAMasterIsPublished() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 12,
                                               minSubs: 5, reseeding: false, enabled: true,
                                               publishedSubs: 11)
        XCTAssertEqual(status, .active(subs: 11),
                       "the caption must report the master actually being served (11), not the 12 registered subs")
    }

    /// The state that was previously reported as `.active` and was a lie: eligible and past the
    /// quorum, but no clean master published yet, so the outputs are still the online master.
    /// A real 17-sub M51 session sat here the entire time while the caption claimed a clean master.
    func testBuildingWhenEligibleButNothingPublishedYet() {
        let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: true, subCount: 12,
                                               minSubs: 5, reseeding: false, enabled: true,
                                               publishedSubs: nil)
        XCTAssertEqual(status, .building(subs: 12))
    }

    /// Ineligibility still outranks publication state — a stale master must never read as active.
    func testOffOutranksAPublishedMaster() {
        for (local, on, expected) in [(false, true, "network source"), (true, false, "turned off")] {
            let status = LiveRejectionGate.reason(sourceIsLocalLiveRelay: local, subCount: 12,
                                                   minSubs: 5, reseeding: false, enabled: on,
                                                   publishedSubs: 11)
            XCTAssertEqual(status, .off(reason: expected))
        }
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

    // MARK: - isLocalPath (D9: the path-locality half of AppModel.sourceIsLocalLiveRelay)

    /// A real local directory (the process's own temp dir) resolves local.
    func testIsLocalPathTrueForLocalDirectory() {
        XCTAssertTrue(LiveRejectionGate.isLocalPath(FileManager.default.temporaryDirectory))
    }

    /// An unresolvable path (no such volume/file — stand-in for the network-mount case, which
    /// isn't reproducible in a unit test without an actual SMB/AFP/NFS mount) fails CLOSED to
    /// "not local," matching the doc comment's "unresolvable key ... fails closed" guarantee.
    func testIsLocalPathFailsClosedForUnresolvablePath() {
        let bogus = URL(fileURLWithPath: "/no-such-volume-\(UUID().uuidString)/watch")
        XCTAssertFalse(LiveRejectionGate.isLocalPath(bogus))
    }

    // MARK: - sampleBudgetWarning (D9: the threshold arithmetic half of
    // AppModel.advisoryCheckLiveRejectionBudget)

    /// A sensor within the ~34 MP budget threshold (design spec: "6 GB fits ≥11 frames only up to
    /// ~34 MP") fits comfortably — no warning. Real ASI2600MC-Air dims (6248×4176, ~26 MP).
    func testSampleBudgetWarningNilWhenBudgetFits() {
        let warning = LiveRejectionGate.sampleBudgetWarning(
            maxSampleBytes: 6_000_000_000, width: 6248, height: 4176, minFrames: 11)
        XCTAssertNil(warning)
    }

    /// A sensor well past the ~34 MP threshold (8000×6000 = 48 MP) doesn't fit 11 frames in a
    /// 6 GB budget — verifies both the exact bytes/frame estimate (w·h·16, i.e. RGB + mask ×
    /// 4 bytes/component: 8000×6000×16 = 768,000,000 B/frame → 6,000,000,000 / 768,000,000 = 7
    /// frames) and the exact message text `AppModel` used to build inline.
    func testSampleBudgetWarningWhenBudgetDoesNotFit() {
        let warning = LiveRejectionGate.sampleBudgetWarning(
            maxSampleBytes: 6_000_000_000, width: 8000, height: 6000, minFrames: 11)
        XCTAssertEqual(warning, "Live rejection: sample budget (~6 GB) only fits 7 frame(s) "
            + "at 8000×6000 — raise maxSampleBytes for sensors this large.")
    }

    /// Boundary: exactly enough frames (framesThatFit == minFrames) is NOT a warning — the
    /// inline check was strict-less-than (`framesThatFit < minViableSampleFrames`), so an exact
    /// match at the floor must still be nil.
    func testSampleBudgetWarningNilAtExactMinFramesBoundary() {
        // 1000x1000 -> sampleFrameBytes = 16,000,000; budget 160,000,000 -> framesThatFit == 10.
        let warning = LiveRejectionGate.sampleBudgetWarning(
            maxSampleBytes: 160_000_000, width: 1000, height: 1000, minFrames: 10)
        XCTAssertNil(warning)
    }
}
