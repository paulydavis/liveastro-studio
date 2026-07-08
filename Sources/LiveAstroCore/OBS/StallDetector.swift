import Foundation

/// Detects imaging stalls by comparing the elapsed time since the last
/// frame update against a threshold derived from the sub-exposure length.
public struct StallDetector {

    // MARK: - Properties

    /// The stall threshold: `max(multiplier * subExposureSeconds, minimumInterval)`.
    public let threshold: TimeInterval

    private var lastUpdate: Date?

    // MARK: - Init

    public init(subExposureSeconds: Double,
                multiplier: Double = 3,
                minimumInterval: TimeInterval = 90) {
        threshold = max(multiplier * subExposureSeconds, minimumInterval)
    }

    // MARK: - API

    /// Record a frame update at `date`. Resets the stall clock.
    public mutating func recordUpdate(at date: Date) {
        lastUpdate = date
    }

    /// Returns `true` iff a baseline exists AND `date - lastUpdate > threshold`.
    /// Returns `false` when no update has ever been recorded.
    public func isStalled(at date: Date) -> Bool {
        guard let last = lastUpdate else { return false }
        return date.timeIntervalSince(last) > threshold
    }
}
