import Foundation

/// Batch imports do not produce registration-quality SubFrameRecords. Keep their
/// accepted exposures separately, in commit order, without inventing quality metrics.
public struct ImportedFrameExposure: Codable, Equatable {
    public let index: Int
    public let sourceFile: String
    public let exposure: FrameExposure
}

/// One captured sub's exposure. Estimates retain their provenance across re-stacks.
public struct FrameExposure: Codable, Equatable, Sendable {
    public let seconds: Double
    public let estimated: Bool

    public init(metadata: SourceMetadata?, fallback: Double) {
        seconds = SourceMetadata.resolvedExposureSeconds(metadata: metadata, fallback: fallback)
        estimated = metadata?.validExposureSeconds == nil
    }
}

/// Travels with a particular stack's pixels, never inferred from a session-wide count.
public struct ExposureSummary: Codable, Equatable, Sendable {
    public private(set) var totalSeconds: Double = 0
    public private(set) var frameCount: Int = 0
    public private(set) var estimatedFrameCount: Int = 0
    public private(set) var uniformSeconds: Double?

    public init() {}

    public mutating func add(_ exposure: FrameExposure) {
        uniformSeconds = frameCount == 0 ? exposure.seconds
            : (uniformSeconds == exposure.seconds ? uniformSeconds : nil)
        totalSeconds += exposure.seconds
        frameCount += 1
        if exposure.estimated { estimatedFrameCount += 1 }
    }

    /// Legacy/watcher data has no per-sub provenance. Never advertise this reconstruction as exact.
    public static func estimated(count: Int, seconds: Double) -> Self {
        var result = Self()
        let exposure = FrameExposure(metadata: nil, fallback: seconds)
        for _ in 0..<max(0, count) { result.add(exposure) }
        return result
    }

    public var caption: String {
        let base: String
        if let uniformSeconds, estimatedFrameCount == 0 {
            base = IntegrationFormat.caption(seconds: totalSeconds, frames: frameCount, subSeconds: uniformSeconds)
        } else {
            let time = IntegrationFormat.caption(seconds: totalSeconds, frames: frameCount, subSeconds: 0)
                .components(separatedBy: " · ")[0]
            base = "\(time) · \(frameCount) subs"
        }
        return estimatedFrameCount == 0 ? base : base + " (\(estimatedFrameCount) estimated)"
    }

    public func masterMetadata(_ source: SourceMetadata?) -> SourceMetadata? {
        var metadata = source ?? SourceMetadata()
        metadata.exposureSeconds = estimatedFrameCount == 0 ? uniformSeconds : nil
        return metadata
    }
}
