import Foundation
import CryptoKit

public struct StackUpdate: Equatable, Sendable {
    public let url: URL
    public let fileSize: Int
}

/// Watches a folder for completed writes of stack images.
/// Siril rewrites live_stack.fit in place, so this is modification-watching with
/// write-completion checks, not new-file detection (spec §5.2).
public final class StackFileWatcher {
    public let updates: AsyncStream<StackUpdate>

    private let folder: URL
    private let quietPeriod: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "liveastro.watcher")
    private var continuation: AsyncStream<StackUpdate>.Continuation!
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var folderFD: Int32 = -1

    /// Per-file state for stability + dedupe. Stability now tracks (size, mtime) so a
    /// preallocated-but-still-filling FITS (full size, advancing mtime) is not emitted early.
    private var lastSeenStat: [String: (size: Int, mtime: TimeInterval)] = [:]
    private var lastEmittedDigest: [String: String] = [:]

    private let fileNamePrefix: String?

    private static let maxHeaderBlocks = 32  // generous ceiling; real headers are 1-10 blocks

    public init(folder: URL, quietPeriod: TimeInterval = 0.5, pollInterval: TimeInterval = 2.0,
                fileNamePrefix: String? = nil) {
        self.folder = folder
        self.quietPeriod = quietPeriod
        self.pollInterval = pollInterval
        self.fileNamePrefix = fileNamePrefix
        var cont: AsyncStream<StackUpdate>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() throws {
        folderFD = open(folder.path, O_EVTONLY)
        guard folderFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(folder.path)"])
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD, eventMask: [.write, .extend], queue: queue)
        // Kernel events can't be injected in tests; the poll fallback below
        // exercises the same scheduleScan/scan path.
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        // Apple's DispatchSource contract: the watched fd must stay open until the
        // source's cancellation handler runs — closing it earlier races the kqueue.
        let fd = folderFD
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src

        // Poll fallback: catches events DispatchSource misses (network volumes, in-place mmap writes).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        pollTimer = timer
    }

    public func stop() {
        // The fd is closed by the source's cancel handler, never here (see start()).
        source?.cancel(); source = nil
        pollTimer?.cancel(); pollTimer = nil
        folderFD = -1
        continuation.finish()
    }

    private func scheduleScan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    private func scan() {
        let fm = FileManager.default
        // Folder unmount/delete mid-run degrades to silent idle; exercising this
        // requires OS-level volume teardown, so it stays untested.
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { continue }
            if let prefix = fileNamePrefix, !prefix.isEmpty,
               !name.lowercased().hasPrefix(prefix.lowercased()) { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let isFITS = ImageLoader.fitsExtensions.contains(ext)
            guard isFITS || ImageLoader.bitmapExtensions.contains(ext) else { continue }

            let url = folder.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let stat = (size: size, mtime: mtime)

            let previous = lastSeenStat[name]
            lastSeenStat[name] = stat

            // Stability gate (P1-2): require (size, mtime) unchanged across two consecutive
            // scans for BOTH file kinds. A writer that preallocates the full declared size and
            // then fills pixels in place satisfies size>=declared on the first sighting; the
            // stability requirement holds it back until the in-place writes stop.
            guard previous?.size == stat.size, previous?.mtime == stat.mtime else { continue }

            if isFITS {
                // Bulletproof completeness: header declares exact expected data length (spec §5.2).
                // Combined with the stability gate above, this rejects both truncated files
                // (size<declared) and preallocated-but-unfilled files (stable check).
                guard let head = try? readHead(url: url, bytes: Self.maxHeaderBlocks * FITSReader.blockSize),
                      let header = try? FITSReader.readHeader(head),
                      size >= header.minimumFileSize else { continue }
            }

            guard let digest = contentDigest(url: url, size: size) else { continue }
            guard lastEmittedDigest[name] != digest else { continue }
            lastEmittedDigest[name] = digest
            continuation.yield(StackUpdate(url: url, fileSize: size))
        }
    }

    private func readHead(url: URL, bytes: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        // FileHandle.read returning nil is a framework-level anomaly; the empty-Data
        // fallback yields a truncated-header skip in scan(), which is safe.
        return try fh.read(upToCount: bytes) ?? Data()
    }

    /// Cheap content identity: SHA256 over size + first/last 64 KB.
    /// Returns nil when the file cannot be opened — the caller must skip the file
    /// rather than emit (a random digest would defeat dedupe and yield repeats).
    private func contentDigest(url: URL, size: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        if let head = try? fh.read(upToCount: 65536) { hasher.update(data: head) }
        if size > 131_072 {
            try? fh.seek(toOffset: UInt64(size - 65536))
            if let tail = try? fh.read(upToCount: 65536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
