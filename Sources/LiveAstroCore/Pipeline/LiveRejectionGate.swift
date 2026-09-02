import Foundation

/// Live trail-rejection status for the operator-facing caption (Task 11). The feature is either
/// `.active` (a clean, trail-rejected master is being maintained, with the survivor count that
/// went into it) or `.off` with a human-readable reason — never silently inactive.
public enum LiveRejectionStatus: Equatable {
    case active(subs: Int)
    case off(reason: String)
}

/// Decides WHY live trail-rejection is (in)active, for `CaptureSettingsView`'s caption. Pure and
/// side-effect-free — `AppModel` resolves the inputs (the pipeline can't introspect its own
/// `FrameSource` for locality, so `sourceIsLocalLiveRelay` is computed on the AppModel side; see
/// `AppModel.sourceIsLocalLiveRelay`) and calls this to decide what to show.
public enum LiveRejectionGate {
    /// Precedence (first match wins), pinned by `LiveRejectionGateTests`: the operator's own
    /// toggle beats everything else ("turned off" is the most actionable explanation), then
    /// source locality (a network/watcher/import source can never run the feature, regardless of
    /// sub count), then an in-progress reseed (the survivor set is momentarily being
    /// re-established, so a stale "need ≥ N subs" would be misleading), then the minimum-subs
    /// quorum, else active.
    public static func reason(sourceIsLocalLiveRelay: Bool, subCount: Int, minSubs: Int,
                               reseeding: Bool, enabled: Bool) -> LiveRejectionStatus {
        guard enabled else { return .off(reason: "turned off") }
        guard sourceIsLocalLiveRelay else { return .off(reason: "network source") }
        guard !reseeding else { return .off(reason: "reseeding") }
        guard subCount >= minSubs else { return .off(reason: "need ≥ \(minSubs) subs") }
        return .active(subs: subCount)
    }
}
