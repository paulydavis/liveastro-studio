import Foundation
import CoreGraphics

public enum PipelineError: Error { case renderFailed }

/// Glue: watcher → loader → stretch → broadcast callback + snapshot + manifest (spec §5.1).
/// UI-free so the end-to-end test and the app share the same wiring.
public final class SessionPipeline {
    public let session: SessionManager
    public var onUpdate: ((CGImage, SnapshotRecord) -> Void)?
    public var onLog: ((String) -> Void)?

    private let watcher: StackFileWatcher
    private let profile: SessionProfile
    private let replaySettings: ReplaySettings
    private let maxKeyframes: Int
    private var recorder: SnapshotRecorder?
    private var consumeTask: Task<Void, Never>?

    public init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL,
                replaySettings: ReplaySettings = .init(), maxKeyframes: Int = 45) {
        self.watcher = StackFileWatcher(folder: watchFolder)
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
    }

    public func start() throws {
        let dir = try session.startSession(profile: profile)
        recorder = SnapshotRecorder(sessionDirectory: dir)
        try watcher.start()
        consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let stream = self?.watcher.updates else { return }
            for await update in stream {
                self?.handle(update)
            }
        }
    }

    private func handle(_ update: StackUpdate) {
        do {
            let linear = try ImageLoader.load(url: update.url)
            let display = linear.sourceIsLinear ? AutoStretch.stretch(linear) : linear
            guard let cg = AutoStretch.makeCGImage(display) else {
                throw ImageLoaderError.decodeFailed("CGImage packing")
            }
            let index = session.acceptedCount + 1
            let record = try recorder!.save(
                cgImage: cg, linear: linear, sourceFile: update.url.lastPathComponent,
                index: index, timestamp: Date(),
                estimatedIntegrationSeconds: Double(index) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
        } catch {
            // Spec §7: skip bad updates, keep the last good frame on the broadcast.
            onLog?("Skipped update (\(update.url.lastPathComponent)): \(error)")
        }
    }

    /// Ends the session and renders replay.mp4. Synchronous — call off the main thread.
    public func end() throws -> URL {
        watcher.stop()
        consumeTask?.cancel()
        try session.endSession()
        guard let dir = session.sessionDirectory, let manifest = session.manifest else {
            throw SessionError.notRunning
        }
        let snapshots = manifest.snapshots
        let urls = snapshots.map { dir.appendingPathComponent($0.snapshotFile) }
        let outputURL = dir.appendingPathComponent("replay.mp4")
        guard !urls.isEmpty else { return outputURL } // empty session: no replay to render
        let picked = try FrameSelector.selectSnapshots(urls: urls, maxKeyframes: maxKeyframes)
        let keyframes = picked.map { i in
            ReplayKeyframe(
                imageURL: urls[i],
                caption: "\(manifest.targetName) — " + IntegrationFormat.caption(
                    seconds: snapshots[i].estimatedIntegrationSeconds,
                    frames: snapshots[i].index,
                    subSeconds: manifest.subExposureSeconds))
        }
        try ReplayGenerator(settings: replaySettings).render(keyframes: keyframes, to: outputURL)
        return outputURL
    }
}
