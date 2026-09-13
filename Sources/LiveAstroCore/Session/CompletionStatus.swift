import Foundation

/// Pure builder for the Live-tab "session end" status line — a testable seam so
/// the display logic isn't tangled in the SwiftUI view (P3 follow-on review).
///
/// The idle safeguard is native-stacking only (`writeMasterSnapshot` can't save a
/// master when an external stacker owns it, and the tick ignores idle in that
/// mode), so this must NOT advertise "idle-safe" outside native mode. Planned
/// stop works in any mode. Returns nil when nothing is showable.
public enum CompletionStatus {
    /// - Parameters:
    ///   - plannedDeadline: the next-occurrence deadline the driver fires on (the
    ///     caller computes it from the shared armed-at anchor); nil omits the segment.
    ///   - isNativeStacking: gates the idle-safe segment.
    ///   - clockString: formats a deadline as a wall-clock time (injected so the
    ///     pure logic stays locale/timezone-free and testable).
    public static func line(plannedStopEnabled: Bool,
                            plannedDeadline: Date?,
                            idleSafeguardEnabled: Bool,
                            idleSafeguardMinutes: Int,
                            isNativeStacking: Bool,
                            now: Date,
                            clockString: (Date) -> String) -> String? {
        var parts: [String] = []
        if plannedStopEnabled, let deadline = plannedDeadline {
            let remaining = deadline.timeIntervalSince(now)
            if remaining < 3600 {
                // Floor, not round: this is a countdown, so N is full minutes
                // remaining. Rounding would show "60 min" for [3570,3600) — a
                // nonsense value inside the under-an-hour branch.
                parts.append("Auto-stop in \(max(0, Int(remaining / 60))) min")
            } else {
                parts.append("Auto-stop \(clockString(deadline))")
            }
        }
        if idleSafeguardEnabled, isNativeStacking {
            parts.append("idle-safe \(idleSafeguardMinutes) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
