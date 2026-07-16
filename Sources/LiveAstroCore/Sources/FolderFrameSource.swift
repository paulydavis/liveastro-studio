import Foundation

/// Reads raw frames from a folder, either as a one-shot import or by watching for new files.
///
/// Import mode is PULL-based: one file is loaded per consumer pull (`AsyncStream(unfolding:)`),
/// so peak memory stays O(1) frames regardless of folder size. Live mode remains push-based
/// from the file watcher (frame cadence is ~20s, so buffering is not a concern).
public final class FolderFrameSource: FrameSource {

    public enum Mode { case importOnce, live }

    public let frames: AsyncStream<RawFrame>
    public var isFinite: Bool { mode == .importOnce }
    public let totalCount: Int?
    /// Logging seam (mirrors FrameRelay.onLog). Forwarded to the inner StackFileWatcher
    /// when in live mode so folder-disappearance events surface in the app log.
    public var onLog: ((String) -> Void)?
    /// Live mode only; nil in import mode (which uses the pull-based cursor instead).
    private var continuation: AsyncStream<RawFrame>.Continuation?

    private let folder: URL
    private let mode: Mode
    private let fileNamePrefix: String?

    private let importCursor: ImportCursor?
    private var liveTask: Task<Void, Never>?
    private var watcher: StackFileWatcher?

    public init(folder: URL, mode: Mode, fileNamePrefix: String? = nil) {
        self.folder = folder
        self.mode = mode
        self.fileNamePrefix = fileNamePrefix

        switch mode {
        case .importOnce:
            let cursor = ImportCursor(folder: folder, fileNamePrefix: fileNamePrefix)
            // Snapshot eagerly so totalCount is available before start() is called.
            cursor.snapshotIfNeeded()
            self.importCursor = cursor
            self.totalCount = cursor.fileCount
            self.continuation = nil
            // One file is read per pull; unreadable files are skipped without buffering.
            self.frames = AsyncStream(unfolding: {
                while !Task.isCancelled {
                    guard let url = cursor.next() else { return nil }
                    if let frame = try? FolderFrameSource.loadRawFrame(url: url) {
                        return frame
                    }
                }
                return nil
            })

        case .live:
            self.importCursor = nil
            self.totalCount = nil
            var cont: AsyncStream<RawFrame>.Continuation!
            // AsyncStream's init runs this closure synchronously; cont is non-nil here.
            self.frames = AsyncStream { cont = $0 }
            self.continuation = cont
        }
    }

    public func start() throws {
        switch mode {
        case .importOnce:
            // Pull-based: just snapshot the sorted file list; loading happens per pull.
            importCursor?.snapshotIfNeeded()

        case .live:
            // Review7 P2: native relay / rig folders publish each sub ONCE and
            // never touch it again — an already-emitted identity is trusted, so
            // every poll costs one fstat per file instead of re-hashing the
            // whole (ever-growing) folder each scan.
            let w = StackFileWatcher(folder: folder, fileNamePrefix: fileNamePrefix,
                                     digestPolicy: .immutableAfterPublish)
            w.onLog = onLog   // forward folder-disappearance events to the app log
            self.watcher = w
            try w.start()
            let continuation = self.continuation!
            let log = onLog
            liveTask = Task.detached {
                for await update in w.updates {
                    if let frame = FolderFrameSource.frame(for: update, log: log) {
                        continuation.yield(frame)
                    }
                }
                // Normally unreachable: the watcher stream only ends via stop(),
                // which finishes the continuation itself. Kept as a backstop so
                // consumers never hang on a dead stream.
                continuation.finish()
            }
        }
    }

    /// Protocol stop: bounded by the inner watcher's own 5 s default.
    public func stop() { stop(timeout: 5.0) }

    /// Bounded stop (cold1 M1): `timeout` caps the inner watcher's stop so a caller with
    /// an overall shutdown budget (SessionPipeline.end() charges this against its primary
    /// drain deadline) is never pinned behind the watcher default ON TOP of its own drain.
    public func stop(timeout: TimeInterval) {
        stopSeamLock.withLock { _lastStopTimeout = timeout }
        importCursor?.stop()
        watcher?.stop(timeout: timeout)
        liveTask?.cancel()
        continuation?.finish()
    }

    /// Test seam (cold1 M1): the timeout the most recent stop() ran with — pins the
    /// budget plumbing without wall-clock assertions. Lock-guarded: stop() may come from
    /// any thread.
    private let stopSeamLock = NSLock()
    private var _lastStopTimeout: TimeInterval?
    internal var lastStopTimeout: TimeInterval? { stopSeamLock.withLock { _lastStopTimeout } }

    /// Lazily-advanced sorted file list for import mode. Thread-safe: pulls come from the
    /// consumer's task, stop() may come from another thread.
    private final class ImportCursor: @unchecked Sendable {
        private let lock = NSLock()
        private let folder: URL
        private let fileNamePrefix: String?
        private var files: [URL]?   // nil until first snapshot
        private var index = 0
        private var stopped = false

        init(folder: URL, fileNamePrefix: String?) {
            self.folder = folder
            self.fileNamePrefix = fileNamePrefix
        }

        func snapshotIfNeeded() {
            lock.withLock { snapshotLocked() }
        }

        /// Number of files in the snapshot; 0 before snapshotIfNeeded() is called.
        var fileCount: Int {
            lock.withLock { files?.count ?? 0 }
        }

        func stop() {
            lock.withLock { stopped = true }
        }

        /// Next file to load, or nil at end of list / after stop().
        func next() -> URL? {
            lock.withLock {
                guard !stopped else { return nil }
                snapshotLocked()
                guard let files, index < files.count else { return nil }
                let url = files[index]
                index += 1
                return url
            }
        }

        private func snapshotLocked() {
            guard files == nil else { return }
            let fm = FileManager.default
            // An unreadable folder yields a silent empty import (stream ends with no
            // frames); the folder's existence is validated upstream by the caller's UI.
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            files = names
                .filter { name in
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard ImageLoader.fitsExtensions.contains(ext) else { return false }
                    if let p = fileNamePrefix, !p.isEmpty {
                        return name.lowercased().hasPrefix(p.lowercased())
                    }
                    return true
                }
                // Numeric-aware order so Light_2 precedes Light_10 (capture sequence order).
                .sorted { $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedAscending }
                .map { folder.appendingPathComponent($0) }
        }
    }

    /// Load one watcher-emitted update into a RawFrame, enforcing the identity the watcher
    /// captured on its pinned per-file descriptor (review5 item 1). Returns nil when the frame
    /// must be skipped: an identity mismatch (the file changed between the watcher's validation
    /// and this read — logged honestly; a boundary failure may lose one frame, never the
    /// session) or an unreadable/undecodable file (pre-existing silent-skip behavior).
    /// Internal seam so the skip-vs-deliver decision is deterministically unit-testable.
    static func frame(for update: StackUpdate, log: ((String) -> Void)?) -> RawFrame? {
        do {
            return try loadRawFrame(url: update.url, expectedIdentity: update.identity)
        } catch let mismatch as FileIdentityMismatchError {
            log?("file changed between validation and read — skipping \(mismatch.fileName)")
            return nil
        } catch {
            return nil
        }
    }

    /// Shared FITS → RawFrame loader (also used by tests). When `expectedIdentity` is supplied,
    /// the file is opened once, fstat-verified against the identity on THAT descriptor, read
    /// from the same descriptor (with a content-digest re-check), and decoded FROM THOSE BYTES
    /// (`FileIdentityMismatchError` on mismatch). nil identity = plain path read, unchanged.
    public static func loadRawFrame(url: URL, expectedIdentity: FileIdentity? = nil) throws -> RawFrame {
        let data = try FileIdentity.read(url: url, verifying: expectedIdentity)
        let header = try FITSReader.readHeader(data)
        let bayerPattern = BayerPattern(headerValue: header.bayerPattern)
        let bottomUp = header.bottomUp
        let dateObs = header.dateObs
        let metadata = SourceMetadata(fitsKeywords: header.keywords)

        let fitsImage = try FITSReader.read(data, normalizeRowOrder: false)
        let image = AstroImage(width: fitsImage.width, height: fitsImage.height,
                               channels: fitsImage.channels, pixels: fitsImage.pixels,
                               sourceIsLinear: true)

        let timestamp: Date
        if let dateStr = dateObs {
            let fmtFractional = ISO8601DateFormatter()
            fmtFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]
            if let d = fmtFractional.date(from: dateStr) ?? fmtPlain.date(from: dateStr) {
                timestamp = d
            } else {
                timestamp = modDate(url: url)
            }
        } else {
            timestamp = modDate(url: url)
        }

        return RawFrame(image: image, bayerPattern: bayerPattern, bottomUp: bottomUp,
                        timestamp: timestamp, sourceName: url.lastPathComponent,
                        metadata: metadata)
    }

    // Date() fallback covers the file vanishing between load and attribute read
    // (a race we can't test deterministically); the timestamp is advisory-only.
    private static func modDate(url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date()
    }
}
