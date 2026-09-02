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

    /// Whether `url` resolves to a LOCAL filesystem location (D9) — the path-locality half of
    /// `AppModel.sourceIsLocalLiveRelay`. `.volumeIsLocalKey` is macOS's own local-vs-network-mount
    /// distinction (SMB/AFP/NFS shares — the ASIAIR/NINA network case — read false); an
    /// unresolvable key (folder deleted, permission issue, no such volume) fails closed to "not
    /// local" rather than silently reporting local. The other half — "is this even a native-stack
    /// session" — stays on `AppModel` since `SourceMode` is an app-only type `LiveAstroCore`
    /// cannot depend on.
    public static func isLocalPath(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false
    }

    /// Pure form of Task 11 point 6's advisory sample-budget check (D9): whether `maxSampleBytes`
    /// comfortably fits at least `minFrames` samples at `width`×`height`, and if not, the exact
    /// warning message `AppModel.advisoryCheckLiveRejectionBudget` logs. Assumes the refiner's
    /// post-debayer working format (RGB warped image + a 1-channel mask, 4 bytes/component — see
    /// the design spec's sample-policy math), independent of the raw FITS `channels` (mono
    /// cameras still warp/mask in this same shape). Returns `nil` when the budget fits >= minFrames.
    public static func sampleBudgetWarning(maxSampleBytes: Int, width: Int, height: Int,
                                            minFrames: Int) -> String? {
        let sampleFrameBytes = width * height * 16   // (3 RGB + 1 mask) channels × 4 bytes/component
        let framesThatFit = maxSampleBytes / sampleFrameBytes
        guard framesThatFit < minFrames else { return nil }
        return "Live rejection: sample budget (~\(maxSampleBytes / 1_000_000_000) GB) only fits "
            + "\(framesThatFit) frame(s) at \(width)×\(height) — raise maxSampleBytes for sensors this large."
    }
}
