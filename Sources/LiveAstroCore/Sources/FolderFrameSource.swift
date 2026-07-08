import Foundation

/// Reads raw frames from a folder, either as a one-shot import or by watching for new files.
public final class FolderFrameSource: FrameSource {

    public enum Mode { case importOnce, live }

    public let frames: AsyncStream<RawFrame>
    private var continuation: AsyncStream<RawFrame>.Continuation!

    private let folder: URL
    private let mode: Mode
    private let fileNamePrefix: String?

    private var importTask: Task<Void, Never>?
    private var watcher: StackFileWatcher?

    public init(folder: URL, mode: Mode, fileNamePrefix: String? = nil) {
        self.folder = folder
        self.mode = mode
        self.fileNamePrefix = fileNamePrefix
        var cont: AsyncStream<RawFrame>.Continuation!
        self.frames = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() throws {
        switch mode {
        case .importOnce:
            let folder = self.folder
            let fileNamePrefix = self.fileNamePrefix
            let continuation = self.continuation!
            importTask = Task.detached {
                let fm = FileManager.default
                guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
                    continuation.finish()
                    return
                }
                let sorted = names
                    .filter { name in
                        let ext = (name as NSString).pathExtension.lowercased()
                        guard ImageLoader.fitsExtensions.contains(ext) else { return false }
                        if let p = fileNamePrefix, !p.isEmpty {
                            return name.lowercased().hasPrefix(p.lowercased())
                        }
                        return true
                    }
                    .sorted()
                for name in sorted {
            guard !Task.isCancelled else { break }
                    let url = folder.appendingPathComponent(name)
                    if let frame = try? FolderFrameSource.loadRawFrame(url: url) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }

        case .live:
            let w = StackFileWatcher(folder: folder, fileNamePrefix: fileNamePrefix)
            self.watcher = w
            try w.start()
            let continuation = self.continuation!
            importTask = Task.detached {
                for await update in w.updates {
                    if let frame = try? FolderFrameSource.loadRawFrame(url: update.url) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
        }
    }

    public func stop() {
        watcher?.stop()
        importTask?.cancel()
        continuation.finish()
    }

    /// Shared FITS → RawFrame loader (also used by tests).
    public static func loadRawFrame(url: URL) throws -> RawFrame {
        let data = try Data(contentsOf: url)
        let header = try FITSReader.readHeader(data)
        let bayerPattern = BayerPattern(headerValue: header.bayerPattern)
        let bottomUp = header.bottomUp
        let dateObs = header.dateObs

        let fitsImage = try FITSReader.read(data)
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
                        timestamp: timestamp, sourceName: url.lastPathComponent)
    }

    private static func modDate(url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date()
    }
}
