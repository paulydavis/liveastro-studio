import Foundation

/// User-facing completion settings (a value copy of the relevant SessionSettings
/// fields, so the pure logic doesn't depend on the whole settings type).
public struct CompletionSettings: Equatable {
    public var idleSafeguardEnabled: Bool
    public var idleSafeguardMinutes: Int
    public var plannedStopEnabled: Bool
    public var plannedStopHour: Int
    public var plannedStopMinute: Int
    public init(idleSafeguardEnabled: Bool, idleSafeguardMinutes: Int,
                plannedStopEnabled: Bool, plannedStopHour: Int, plannedStopMinute: Int) {
        self.idleSafeguardEnabled = idleSafeguardEnabled
        self.idleSafeguardMinutes = idleSafeguardMinutes
        self.plannedStopEnabled = plannedStopEnabled
        self.plannedStopHour = plannedStopHour
        self.plannedStopMinute = plannedStopMinute
    }
}

public enum CompletionAction: Equatable { case none, safeguard, endSession }

/// Pure decision logic for session completion (spec §2). No side effects — the
/// driver owns the clock, the fired flags, and the actions.
public enum SessionCompletionMonitor {

    /// The next occurrence of `hour:minute` at or after `reference` (crosses
    /// midnight). If today's occurrence is already strictly before `reference`,
    /// roll to tomorrow.
    public static func plannedStopDeadline(after reference: Date, hour: Int, minute: Int,
                                           calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: reference)
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let todayAt = calendar.date(byAdding: comps, to: today) ?? reference
        if todayAt >= reference { return todayAt }
        return calendar.date(byAdding: .day, value: 1, to: todayAt) ?? todayAt
    }

    public static func decide(now: Date, lastAcceptedFrame: Date?, settings: CompletionSettings,
                              safeguardAlreadyFiredThisIdle: Bool, plannedStopAlreadyFired: Bool,
                              calendar: Calendar = .current) -> CompletionAction {
        // Planned stop takes priority when both are due.
        if settings.plannedStopEnabled, !plannedStopAlreadyFired {
            // Resolve the deadline relative to a reference EARLIER than now so the
            // "next occurrence" is the one we've reached. Using now itself for a
            // time that just passed today would roll to tomorrow; so compare the
            // deadline computed from the start of today.
            let today = calendar.startOfDay(for: now)
            var comps = DateComponents(); comps.hour = settings.plannedStopHour; comps.minute = settings.plannedStopMinute
            if let todayAt = calendar.date(byAdding: comps, to: today), now >= todayAt {
                return .endSession
            }
        }
        if settings.idleSafeguardEnabled, !safeguardAlreadyFiredThisIdle, let last = lastAcceptedFrame {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= Double(settings.idleSafeguardMinutes) * 60 { return .safeguard }
        }
        return .none
    }
}
