import Foundation

/// Display adjustments split into what the audience currently sees (`committed`) and what the
/// operator is editing (`pending`).
///
/// Before this, `AppModel.applyDisplayAdjustments()` pushed every slider tick straight into
/// `SessionPipeline.displayAdjustments`, which feeds the broadcast, snapshots, `latest.png`,
/// replay and `master.fit` — so tuning mid-stream published every intermediate state. Only
/// `apply()` promotes `pending`, and only `committed` is ever handed to the pipeline or
/// persisted.
///
/// Deliberately a plain value type with no UI or pipeline dependency: it lives in
/// `LiveAstroCore` because `LiveAstroStudio` has no test target, and this is the invariant
/// the feature rests on.
public struct StagedAdjustments: Equatable {
    /// What the pipeline holds — the broadcast, the recorded artifacts, and the persisted set.
    public private(set) var committed: DisplayAdjustments
    /// What the sliders bind to. Never reaches the pipeline, never persisted.
    public var pending: DisplayAdjustments

    public init(committed: DisplayAdjustments) {
        self.committed = committed
        self.pending = committed
    }

    /// Drives the panel's pending treatment and the enabled state of Apply/Revert.
    public var hasPendingChanges: Bool { pending != committed }

    /// Promotes `pending` and RETURNS the new committed value, so the caller pushes exactly
    /// what was committed rather than re-reading state that may have moved.
    public mutating func apply() -> DisplayAdjustments {
        committed = pending
        return committed
    }

    /// Throws the pending edits away.
    public mutating func revert() {
        pending = committed
    }
}
