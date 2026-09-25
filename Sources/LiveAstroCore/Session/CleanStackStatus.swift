import Foundation

/// A reason reported by the pass that actually ran, never inferred from elapsed time.
public enum CleanStackFailure: String, Codable, Error, LocalizedError, Sendable {
    case timedOut = "timed_out"
    case cancelled
    case unreadableInputs = "unreadable_inputs"
    case insufficientFrames = "insufficient_frames"
    case insufficientMemoryBudget = "insufficient_memory_budget"
    case combinationFailed = "combination_failed"

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "The final clean-stack time limit was reached."
        case .cancelled: return "Clean-stack processing was cancelled."
        case .unreadableInputs: return "Some inputs could not be loaded or verified within the per-file limit."
        case .insufficientFrames: return "Too few usable frames remain for trail rejection."
        case .insufficientMemoryBudget: return "The rejection sample exceeds the configured memory budget."
        case .combinationFailed: return "The clean-stack calculation could not produce a master."
        }
    }
}

/// Saved-master facts, separate from session intake totals and the online stack's count.
/// Expected means the frozen, eligible survivors: excludes user rejects and older reseeds.
public struct CleanStackStatus: Codable, Equatable, Sendable {
    public let expectedCount: Int
    public let savedCount: Int
    public let expectedExposure: ExposureSummary
    public let savedExposure: ExposureSummary
    public let savedClean: Bool
    public let reason: CleanStackFailure?

    public var needsCompletion: Bool { !savedClean || savedCount < expectedCount }
    public var message: String {
        let detail: String
        if savedClean {
            let missing = max(0, expectedExposure.totalSeconds - savedExposure.totalSeconds)
            let estimated = expectedExposure.estimatedFrameCount > 0 || savedExposure.estimatedFrameCount > 0
            detail = "\(savedCount) of \(expectedCount) eligible accepted frames saved in the clean master"
                + (missing > 0 ? String(format: "; %.1f seconds not included%@", missing, estimated ? " (estimated)" : "") : "") + "."
        } else {
            detail = "Clean stack unfinished: saved an online master without final trail rejection. \(expectedCount) eligible accepted frames."
        }
        return detail + (reason.map { " " + ($0.errorDescription ?? $0.rawValue) } ?? "")
    }
}
