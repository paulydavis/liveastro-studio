import Foundation

/// Parsed OBS `GetStreamStatus` response — the broadcast-health readout.
public struct StreamHealth: Equatable {
    public let active: Bool
    public let durationSeconds: Double    // outputDuration (ms) → seconds
    public let skippedFrames: Int         // outputSkippedFrames
    public let totalFrames: Int           // outputTotalFrames
    public let congestion: Double         // outputCongestion, clamped [0,1]

    public init(active: Bool, durationSeconds: Double, skippedFrames: Int,
                totalFrames: Int, congestion: Double) {
        self.active = active
        self.durationSeconds = durationSeconds
        self.skippedFrames = skippedFrames
        self.totalFrames = totalFrames
        self.congestion = congestion
    }

    public var droppedFraction: Double {
        totalFrames > 0 ? Double(skippedFrames) / Double(totalFrames) : 0
    }

    /// Parse a GetStreamStatus responseData dict. Returns nil if `outputActive`
    /// is absent (not a valid status). OBS-ws numbers may be Int or Double.
    public static func parse(_ dict: [String: Any]) -> StreamHealth? {
        guard let active = dict["outputActive"] as? Bool else { return nil }
        func num(_ key: String) -> Double {
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        return StreamHealth(
            active: active,
            durationSeconds: num("outputDuration") / 1000.0,
            skippedFrames: Int(num("outputSkippedFrames")),
            totalFrames: Int(num("outputTotalFrames")),
            congestion: min(max(num("outputCongestion"), 0), 1))
    }
}
