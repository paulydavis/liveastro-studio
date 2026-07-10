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
            let w = StackFileWatcher(folder: folder, fileNamePrefix: fileNamePrefix)
            self.watcher = w
            try w.start()
            let continuation = self.continuation!
            liveTask = Task.detached {
                for await update in w.updates {
                    if let frame = try? FolderFrameSource.loadRawFrame(url: update.url) {
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

    public func stop() {
        importCursor?.stop()
        watcher?.stop()
        liveTask?.cancel()
        continuation?.finish()
    }

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

    /// Shared FITS → RawFrame loader (also used by tests).
    public static func loadRawFrame(url: URL) throws -> RawFrame {
        let data = try Data(contentsOf: url)
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
