import XCTest
@testable import LiveAstroCore

/// This type exists in LiveAstroCore rather than AppModel for one reason: LiveAstroStudio is
/// an executableTarget with no test target (Package.swift:12,18), so state living there can
/// only be checked by grepping source text. The staging invariant is the property the whole
/// feature rests on, so it gets a real test.
final class StagedAdjustmentsTests: XCTestCase {

    private func adj(blackPoint: Double) -> DisplayAdjustments {
        var a = DisplayAdjustments.neutral
        a.blackPoint = blackPoint
        return a
    }

    /// THE invariant: editing `pending` must never move `committed`, which is what the
    /// pipeline (and therefore the broadcast) reads.
    func testEditingPendingLeavesCommittedUntouched() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        XCTAssertEqual(s.committed.blackPoint, 0.01,
                       "a pending edit must never reach committed — committed is what viewers see")
        XCTAssertTrue(s.hasPendingChanges)
    }

    func testApplyPromotesPendingAndReturnsTheNewCommittedValue() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        let committed = s.apply()
        XCTAssertEqual(committed.blackPoint, 0.19, "apply must RETURN the value to push to the pipeline")
        XCTAssertEqual(s.committed.blackPoint, 0.19)
        XCTAssertFalse(s.hasPendingChanges, "after apply the two sets agree")
    }

    func testRevertDiscardsPendingAndRestoresCommitted() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        s.revert()
        XCTAssertEqual(s.pending.blackPoint, 0.01)
        XCTAssertFalse(s.hasPendingChanges)
    }

    func testFreshStateHasNoPendingChanges() {
        let s = StagedAdjustments(committed: adj(blackPoint: 0.05))
        XCTAssertFalse(s.hasPendingChanges, "a panel must open quiet, with Apply/Revert disabled")
        XCTAssertEqual(s.pending, s.committed)
    }

    /// Editing pending back to the committed value by hand must clear the pending state, or
    /// Apply/Revert would stay lit with nothing to do.
    func testEditingPendingBackToCommittedClearsThePendingState() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        s.pending = adj(blackPoint: 0.01)
        XCTAssertFalse(s.hasPendingChanges)
    }

    /// Apply with nothing pending is a no-op that still returns the committed value, so the
    /// caller can push unconditionally without a special case.
    func testApplyWithNothingPendingIsANoOp() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.05))
        let committed = s.apply()
        XCTAssertEqual(committed.blackPoint, 0.05)
        XCTAssertFalse(s.hasPendingChanges)
    }
}
