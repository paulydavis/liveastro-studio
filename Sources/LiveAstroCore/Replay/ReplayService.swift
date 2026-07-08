import Foundation

/// Re-renders a session's replay.mp4 from its manifest + snapshots on disk (spec §5.8).
/// Used by SessionPipeline.end() and by the app's Regenerate action.
public enum ReplayService {
    @discardableResult
    public static func regenerate(sessionDirectory: URL,
                                  replaySettings: ReplaySettings = .init(),
                                  maxKeyframes: Int = FrameSelector.defaultMaxKeyframes) throws -> URL {
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
        let outputURL = sessionDirectory.appendingPathComponent("replay.mp4")
        let snapshots = manifest.snapshots
        guard !snapshots.isEmpty else { return outputURL }
        let gated = FrameSelector.qualityGate(medians: snapshots.map(\.median))
        let survivors = gated.map { snapshots[$0] }
        let urls = survivors.map { sessionDirectory.appendingPathComponent($0.snapshotFile) }
        let picked = try FrameSelector.selectSnapshots(urls: urls, maxKeyframes: maxKeyframes)
        let keyframes = picked.map { i in
            ReplayKeyframe(
                imageURL: urls[i],
                caption: "\(manifest.targetName) — " + IntegrationFormat.caption(
                    seconds: survivors[i].estimatedIntegrationSeconds,
                    frames: survivors[i].index,
                    subSeconds: manifest.subExposureSeconds))
        }
        try ReplayGenerator(settings: replaySettings).render(keyframes: keyframes, to: outputURL)
        return outputURL
    }
}
