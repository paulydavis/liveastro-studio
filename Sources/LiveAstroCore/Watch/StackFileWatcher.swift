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

    /// Per-file state for stability + dedupe.
    private var lastSeenSize: [String: Int] = [:]
    private var lastEmittedDigest: [String: String] = [:]

    public init(folder: URL, quietPeriod: TimeInterval = 0.5, pollInterval: TimeInterval = 2.0) {
        self.folder = folder
        self.quietPeriod = quietPeriod
        self.pollInterval = pollInterval
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
        src.setEventHandler { [weak self] in self?.scheduleScan() }
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
        source?.cancel(); source = nil
        pollTimer?.cancel(); pollTimer = nil
        if folderFD >= 0 { close(folderFD); folderFD = -1 }
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
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let isFITS = ImageLoader.fitsExtensions.contains(ext)
            guard isFITS || ImageLoader.bitmapExtensions.contains(ext) else { continue }

            let url = folder.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { continue }

            let previousSize = lastSeenSize[name]
            lastSeenSize[name] = size

            if isFITS {
                // Bulletproof completeness: header declares exact expected data length (spec §5.2).
                guard let head = try? readHead(url: url, bytes: 32 * 2880),
                      let header = try? FITSReader.readHeader(head),
                      size >= header.minimumFileSize else { continue }
            } else {
                // Bitmaps: require size stable across two consecutive scans.
                guard previousSize == size else { continue }
            }

            let digest = contentDigest(url: url, size: size)
            guard lastEmittedDigest[name] != digest else { continue }
            lastEmittedDigest[name] = digest
            continuation.yield(StackUpdate(url: url, fileSize: size))
        }
    }

    private func readHead(url: URL, bytes: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try fh.read(upToCount: bytes) ?? Data()
    }

    /// Cheap content identity: SHA256 over size + first/last 64 KB.
    private func contentDigest(url: URL, size: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
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
