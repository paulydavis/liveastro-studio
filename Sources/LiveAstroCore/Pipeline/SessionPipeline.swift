import Foundation
import CoreGraphics

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
    private let consumeDone = DispatchSemaphore(value: 0)

    public init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL,
                replaySettings: ReplaySettings = .init(), maxKeyframes: Int = 45,
                fileNamePrefix: String? = nil) {
        self.watcher = StackFileWatcher(folder: watchFolder, fileNamePrefix: fileNamePrefix)
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
    }

    public func start() throws {
        let dir = try session.startSession(profile: profile)
        recorder = SnapshotRecorder(sessionDirectory: dir)
        try watcher.start()
        let done = consumeDone
        consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let stream = self?.watcher.updates else {
                done.signal()
                return
            }
            for await update in stream {
                self?.handle(update)
            }
            done.signal()
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
    /// Drains any in-flight handle() calls before finalizing the manifest.
    public func end() throws -> URL {
        watcher.stop()
        if consumeTask != nil {
            _ = consumeDone.wait(timeout: .now() + 10)
            consumeTask = nil
        }
        try session.endSession()
        guard let dir = session.sessionDirectory else {
            throw SessionError.notRunning
        }
        return try ReplayService.regenerate(sessionDirectory: dir,
                                            replaySettings: replaySettings,
                                            maxKeyframes: maxKeyframes)
    }
}
