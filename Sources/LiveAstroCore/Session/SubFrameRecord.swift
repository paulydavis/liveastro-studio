import Foundation

/// Where a sub ended up in the stack (spec §Data model).
public enum SubFrameOutcome: String, Codable, Equatable {
    case reference   // became the stack reference (seed)
    case stacked     // accepted and accumulated
    case rejected    // rejected at intake (registration failure)
}

/// A per-sub quality record retained for the session. The measured metrics
/// (`starCount`, `backgroundSigma`, `weight`, `outcome`) are computed once by the
/// stacker and never rewritten; `rejectedByUser` is the operator's flag and the
/// only mutable field. Drives the Stats view and re-stack exclusion.
///
/// NOTE: `recordSubFrame` faithfully persists whatever value the record holds into
/// `manifest.json` — it is NOT a type/writer invariant that the manifest's
/// `rejectedByUser` is false (see `SessionManagerSubFrameTests.
/// testSubFramesPersistAcrossReload`, which records `rejected: true` and reads it back
/// true). Rather, in the CURRENT production flow `onSubFrame` always emits
/// `rejectedByUser: false`, and operator flags are written only to `sub-frames.csv`
/// (never back into the manifest) — so a PRODUCTION manifest happens to show false.
/// That is a property of the production flow, not of the type or `recordSubFrame`. The
/// authoritative user-flag artifact is `sub-frames.csv` (written at session end, at
/// re-stack, and on each post-session toggle). Do not treat manifest `rejectedByUser`
/// as the source of truth for operator flags.
public struct SubFrameRecord: Codable, Equatable {
    public let index: Int
    public let timestamp: Date
    public let sourceFile: String
    public let starCount: Int
    public let backgroundSigma: Float
    public let weight: Float
    public let outcome: SubFrameOutcome
    public let rejectionReason: String?
    public var rejectedByUser: Bool
    /// CONTENT-DIGEST identity of the raw sub file as it was captured, forwarded from the loaded
    /// `RawFrame` (its `digest` is a SHA-256 over the exact decoded bytes; the stat fields are
    /// zero). Lets a post-session re-stack detect a sub whose BYTES were REPLACED on disk since
    /// capture and skip it — validation is digest-only, so inode/mtime churn (Google Drive mirror
    /// / SMB re-sync of byte-identical data) does NOT trigger a false skip. Optional so LEGACY
    /// manifests written before this field decode it as nil (synthesized Codable treats an absent
    /// key as nil) — such subs re-stack unverified, exactly as before. A record whose `digest` is
    /// nil (legacy stat-only) also re-stacks unverified. Not a `sub-frames.csv` column (internal).
    public var identity: FileIdentity?

    public init(index: Int, timestamp: Date, sourceFile: String, starCount: Int,
                backgroundSigma: Float, weight: Float, outcome: SubFrameOutcome,
                rejectionReason: String?, rejectedByUser: Bool, identity: FileIdentity? = nil) {
        self.index = index; self.timestamp = timestamp; self.sourceFile = sourceFile
        self.starCount = starCount; self.backgroundSigma = backgroundSigma
        self.weight = weight; self.outcome = outcome
        self.rejectionReason = rejectionReason; self.rejectedByUser = rejectedByUser
        self.identity = identity
    }
}
