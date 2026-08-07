import Foundation

/// Holds the mutable per-session flags for completion (spec §2): the driver calls
/// `step` each tick; it clears the idle flag when a newer accepted frame appears
/// (re-arm) and marks flags after firing so each trigger fires once.
public struct SessionCompletionDriver {
    public private(set) var safeguardFired = false
    public private(set) var plannedStopFired = false
    private var lastSeenAcceptedFrame: Date?
    public init() {}

    public mutating func step(now: Date, lastAcceptedFrame: Date?, settings: CompletionSettings,
                              calendar: Calendar = .current) -> CompletionAction {
        // Re-arm the safeguard when a NEW accepted frame arrived since we last looked.
        if let last = lastAcceptedFrame, last != lastSeenAcceptedFrame {
            lastSeenAcceptedFrame = last
            safeguardFired = false
        }
        let action = SessionCompletionMonitor.decide(
            now: now, lastAcceptedFrame: lastAcceptedFrame, settings: settings,
            safeguardAlreadyFiredThisIdle: safeguardFired,
            plannedStopAlreadyFired: plannedStopFired, calendar: calendar)
        switch action {
        case .safeguard: safeguardFired = true
        case .endSession: plannedStopFired = true
        case .none: break
        }
        return action
    }

    /// Clears the idle-safeguard flag so the next elapsed tick fires `.safeguard`
    /// again. Used when a fired safeguard did not actually write a master snapshot
    /// (e.g. non-native pipeline or a failed write) and should be retried, without
    /// waiting for a new accepted frame to re-arm.
    public mutating func clearSafeguardForRetry() {
        safeguardFired = false
    }
}
