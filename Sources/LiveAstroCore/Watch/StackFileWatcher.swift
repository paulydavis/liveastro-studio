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

    /// Logging seam (mirrors FrameRelay.onLog). Called on the internal serial queue;
    /// wire to the app log in AppModel just like relay.onLog.
    public var onLog: ((String) -> Void)?

    private let folder: URL
    private let quietPeriod: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "liveastro.watcher")
    private var continuation: AsyncStream<StackUpdate>.Continuation!
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWork: DispatchWorkItem?
    private var folderFD: Int32 = -1

    /// True while the watched folder is absent. Used to log exactly once on
    /// disappearance and once on return, rather than on every poll tick.
    private var folderMissing = false

    /// True while a folder-return re-arm has failed and is being retried on later polls (F4).
    /// Gates the re-arm-failure log to fire once, not every tick, until the re-arm succeeds.
    private var rearmFailed = false

    /// Filesystem identity (device + inode) of a node, used to detect an ATOMIC replacement of the
    /// watched directory (P1, review3): rename(2) of another directory over the same path leaves
    /// `fileExists` true throughout, but the path resolves to a different inode afterward.
    private struct NodeIdentity: Equatable {
        let dev: dev_t
        let ino: ino_t
    }

    /// Identity of the directory the DispatchSource is currently armed on, captured via fstat(2)
    /// on the armed fd in armSource(). nil while no source is armed.
    private var armedIdentity: NodeIdentity?

    /// True once we have logged that a NON-DIRECTORY node occupies the watched path (P2, review3).
    /// Gates that log to fire once per occupation, not every poll tick, while we stay folderMissing.
    private var nonDirectoryAtPathLogged = false

    private static func nodeIdentity(atPath path: String) -> NodeIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return NodeIdentity(dev: st.st_dev, ino: st.st_ino)
    }

    /// Enumerate the directory pinned by the armed `fd` — fd-relative, never by path (review4 P2).
    ///
    /// This closes the mid-scan TOCTOU structurally: `scan()` validates the path's (dev, ino)
    /// identity once at the top, and a swap landing between that check and a PATH-based enumeration
    /// would apply old `lastSeenStat` observations to the NEW directory's files. Enumerating through
    /// the armed fd pins the OLD inode instead — a rename-over unlinks the old directory from the
    /// namespace, but the open fd keeps it readable — so a mid-scan swap is harmless BY
    /// CONSTRUCTION: this scan observes only old-directory contents, and the NEXT scan's identity
    /// check detects the swap and resets state.
    ///
    /// Descriptor discipline: `fdopendir` takes OWNERSHIP of the descriptor it is given (`closedir`
    /// closes it), so the armed fd — owned by the DispatchSource cancel handler — must never be
    /// handed to it, and a `dup()` of the O_EVTONLY fd is unsuitable too (it shares the original's
    /// status flags and seek offset). Instead each call opens a fresh READ descriptor on the same
    /// inode via `openat(fd, ".")` — resolved relative to the fd, not the path — and lets
    /// `closedir` own that. Returns nil when the directory cannot be opened for reading.
    ///
    /// Internal (not private) so the structural property is directly unit-testable
    /// (`testEnumerateDirectory_pinnedFDSeesOldContentsAcrossAtomicSwap`).
    static func enumerateDirectory(fd: Int32) -> [String]? {
        let readFD = openat(fd, ".", O_RDONLY | O_DIRECTORY)
        guard readFD >= 0 else { return nil }
        guard let dir = fdopendir(readFD) else {
            close(readFD)   // fdopendir failed → ownership never transferred; close it ourselves
            return nil
        }
        defer { closedir(dir) }   // closes readFD too
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

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
        try armSource()

        // Poll fallback: catches events DispatchSource misses (network volumes, in-place mmap writes).
        // The timer keeps running even while the folder is missing — it's what detects the return.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        pollTimer = timer
    }

    /// Open the folder fd and arm the DispatchSource.
    /// Called from start() and from scan() when recovering after folder return.
    private func armSource() throws {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(folder.path)"])
        }
        // Capture the armed node's identity (dev, ino) from the fd itself — this is exactly the
        // inode the DispatchSource watches, so scan() can detect an atomic replacement (P1) — and
        // require it to be a DIRECTORY (P2): open(O_EVTONLY) succeeds on a regular file, but a
        // watcher armed on a file can never enumerate; refuse rather than claim recovery. The fd
        // is not yet owned by a cancel handler here, so close it on the refusal path.
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR),
                          userInfo: [NSLocalizedDescriptionKey: "not a directory: \(folder.path)"])
        }
        folderFD = fd
        armedIdentity = NodeIdentity(dev: st.st_dev, ino: st.st_ino)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        // Kernel events can't be injected in tests; the poll fallback below
        // exercises the same scheduleScan/scan path.
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        // Apple's DispatchSource contract: the watched fd must stay open until the
        // source's cancellation handler runs — closing it earlier races the kqueue.
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Cancel and nil out the current DispatchSource (and its fd, via the cancel handler).
    private func cancelSource() {
        source?.cancel()
        source = nil
        folderFD = -1
        armedIdentity = nil
    }

    public func stop() {
        // The fd is closed by the source's cancel handler, never here (see armSource()).
        cancelSource()
        pollTimer?.cancel(); pollTimer = nil
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

        // --- Folder presence check (disappearance + return detection) ---
        // P2 (review3): presence requires an actual DIRECTORY. fileExists(atPath:) accepts any
        // node and open(O_EVTONLY) succeeds on a regular file, so a file sitting at the folder
        // path would otherwise be "recovered" against (arming a source on a file and logging
        // "resuming" while directory enumeration can never work). A non-directory node is treated
        // as still-missing: stay folderMissing, no "resuming" claim, and log the impostor once
        // (not every tick) so the degradation appears honestly.
        var isDirectory: ObjCBool = false
        let nodeExists = fm.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        let folderExists = nodeExists && isDirectory.boolValue

        if !folderExists {
            if !folderMissing {
                // First tick to notice the folder is gone: log once and set flag.
                folderMissing = true
                onLog?("watched folder disappeared — waiting for it to return: \(folder.path)")
                // Cancel the stale DispatchSource fd (bound to the deleted inode).
                cancelSource()
                // F2 (review2): clear the PENDING stability observations. Otherwise a recreated,
                // same-name file whose (size, mtime) happen to match the vanished file's last
                // observation would pass the two-tick stability gate on its very FIRST sighting
                // after return — publishing a still-in-progress FITS. Recreated files must re-earn
                // stability across ticks. The emitted-digest map is RETAINED so dedup survives a
                // disappear→return (a truly identical, already-emitted file is not re-emitted).
                lastSeenStat.removeAll()
            }
            if nodeExists {
                // Something non-directory occupies the watched path. Log once per occupation
                // (gated like folderMissing) — the poll keeps ticking and recovery waits for a
                // real directory.
                if !nonDirectoryAtPathLogged {
                    nonDirectoryAtPathLogged = true
                    onLog?("watched path exists but is not a directory — still waiting for a directory: \(folder.path)")
                }
            } else {
                nonDirectoryAtPathLogged = false
            }
            // While missing, keep the timer running (it will notice the return).
            return
        }
        nonDirectoryAtPathLogged = false

        // P1 (review3): the folder can be REPLACED atomically (rename(2) of another directory over
        // the same path) with NO missing interval — fileExists never reports false, but the
        // DispatchSource is still attached to the OLD inode (events from the new directory reach us
        // only via the poll fallback) and lastSeenStat still holds observations of files that no
        // longer exist (a recreated same-name/size/coarse-mtime file would pass the two-tick
        // stability gate on its first sighting). Compare the path's current (dev, ino) against the
        // identity captured when the source was armed; on mismatch, treat it exactly like a
        // disappear+return in one tick: log honestly, cancel the stale source, clear the pending
        // stability observations (emitted digests RETAINED for dedup), and fall into the recovery
        // branch below — which re-arms BEFORE claiming recovery and retries on later polls if the
        // re-arm fails (mirrors the existing return path).
        if !folderMissing, let armed = armedIdentity,
           let current = Self.nodeIdentity(atPath: folder.path), current != armed {
            onLog?("watched folder was replaced — re-arming: \(folder.path)")
            cancelSource()
            lastSeenStat.removeAll()
            folderMissing = true
        }

        if folderMissing {
            // Folder just came back. F4 (review2): attempt the re-arm FIRST, and only claim recovery
            // (log "resuming" + clear folderMissing) once it SUCCEEDS. Previously "resuming" was logged
            // and the flag cleared BEFORE armSource(), whose failure was silently swallowed — the
            // watcher claimed it had recovered while the DispatchSource was dead. On failure, log once
            // (gated by rearmFailed to avoid per-tick spam) and stay folderMissing so a later poll
            // retries. The poll timer keeps ticking regardless, so scans continue either way.
            do {
                try armSource()
                onLog?("watched folder returned — resuming: \(folder.path)")
                folderMissing = false
                rearmFailed = false
            } catch {
                if !rearmFailed {
                    rearmFailed = true
                    onLog?("watched folder returned but re-arm failed — retrying on later polls: \(folder.path) (\(error))")
                }
                // Stay folderMissing; the poll scan still runs below via the timer, and the next
                // poll re-enters this branch to retry the re-arm.
            }
        }

        // Review4 P2: enumerate + stat through the ARMED fd, never by path. The identity check
        // above and this enumeration are not atomic; a swap landing between them must not let this
        // pass apply old lastSeenStat observations to the new directory's files. The fd pins the
        // inode the identity check approved, so this scan structurally observes only that
        // directory's contents; the NEXT scan detects the swap and resets state. When no source is
        // armed (folderFD < 0, i.e. a failed re-arm while folderMissing), there is nothing safe to
        // enumerate — skip this tick; the poll timer retries the re-arm on the next tick.
        guard folderFD >= 0, let names = Self.enumerateDirectory(fd: folderFD) else { return }
        for name in names {
            guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { continue }
            if let prefix = fileNamePrefix, !prefix.isEmpty,
               !name.lowercased().hasPrefix(prefix.lowercased()) { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let isFITS = ImageLoader.fitsExtensions.contains(ext)
            guard isFITS || ImageLoader.bitmapExtensions.contains(ext) else { continue }

            let url = folder.appendingPathComponent(name)
            // fd-relative per-file stat (fstatat does not consume folderFD) — the stability
            // observation is taken from the same pinned directory the enumeration saw.
            var st = Darwin.stat()
            guard fstatat(folderFD, name, &st, 0) == 0 else { continue }
            let size = Int(st.st_size)
            guard size > 0 else { continue }
            let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                      + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
            let stat = (size: size, mtime: mtime)

            let previous = lastSeenStat[name]
            lastSeenStat[name] = stat

            // Stability gate (P1-2): require (size, mtime) unchanged across two consecutive
            // scans for BOTH file kinds. A writer that preallocates the full declared size and
            // then fills pixels in place satisfies size>=declared on the first sighting; the
            // stability requirement holds it back until the in-place writes stop.
            guard previous?.size == stat.size, previous?.mtime == stat.mtime else { continue }

            // HONEST NOTE (review4 P2): the CONTENT reads below (FITS header + digest) remain
            // PATH-based (FileHandle(forReadingFrom:)). The structural fd-relative fix above closes
            // the STATE-consistency hole (old lastSeenStat applied to new-directory files); a swap
            // racing a content read can at worst read a different file's bytes, which the existing
            // stability + digest gates already protect against (an unstable or changed file is
            // held back / re-observed on the next scan, and dedup is digest-keyed).
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
