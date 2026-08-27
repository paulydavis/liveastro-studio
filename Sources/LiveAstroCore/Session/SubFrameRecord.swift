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

    public init(index: Int, timestamp: Date, sourceFile: String, starCount: Int,
                backgroundSigma: Float, weight: Float, outcome: SubFrameOutcome,
                rejectionReason: String?, rejectedByUser: Bool) {
        self.index = index; self.timestamp = timestamp; self.sourceFile = sourceFile
        self.starCount = starCount; self.backgroundSigma = backgroundSigma
        self.weight = weight; self.outcome = outcome
        self.rejectionReason = rejectionReason; self.rejectedByUser = rejectedByUser
    }
}
