import Foundation
import CryptoKit

/// Identity of the exact file VERSION the watcher validated, captured with fstat(2) on the
/// watcher's pinned per-file descriptor (review5 item 1): (dev, ino) name the inode, (size,
/// mtime at nanosecond precision) pin the content version, and `digest` (when present) is the
/// watcher's content digest over the same descriptor. Consumers use `read(url:verifying:)` to
/// refuse a file that was replaced between the watcher's validation and their own read.
public struct FileIdentity: Equatable, Sendable {
    public let dev: Int64
    public let ino: UInt64
    public let size: Int
    /// st_mtimespec at full nanosecond precision — both producer and consumer derive these from
    /// the same fstat fields so equality is exact, never Date/TimeInterval-rounded.
    public let mtimeSec: Int64
    public let mtimeNsec: Int64
    /// FULL-FILE streaming SHA-256 over size + every byte (the watcher's dedup digest — review6
    /// finding 2: the former head/tail sample missed middle-only changes). nil when the producer
    /// did not compute one (e.g. a bare stability observation); consumers recompute it over the
    /// bytes they actually loaded and compare — strict content-version validation.
    public let digest: String?

    public init(dev: Int64, ino: UInt64, size: Int, mtimeSec: Int64, mtimeNsec: Int64,
                digest: String? = nil) {
        self.dev = dev
        self.ino = ino
        self.size = size
        self.mtimeSec = mtimeSec
        self.mtimeNsec = mtimeNsec
        self.digest = digest
    }

    init(stat st: Darwin.stat, digest: String? = nil) {
        self.init(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int(st.st_size),
                  mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec),
                  digest: digest)
    }

    /// True when `st` describes the same inode and content version (digest not considered —
    /// a stat cannot know it; digest validation happens over the loaded bytes).
    func matches(stat st: Darwin.stat) -> Bool {
        dev == Int64(st.st_dev) && ino == UInt64(st.st_ino) && size == Int(st.st_size)
            && mtimeSec == Int64(st.st_mtimespec.tv_sec) && mtimeNsec == Int64(st.st_mtimespec.tv_nsec)
    }

    /// The same stat identity annotated with a computed content digest.
    func withDigest(_ digest: String) -> FileIdentity {
        FileIdentity(dev: dev, ino: ino, size: size, mtimeSec: mtimeSec, mtimeNsec: mtimeNsec,
                     digest: digest)
    }

    /// Identity currently at `url` (stat by path; digest not computed). Consumer/test convenience.
    public static func capture(url: URL) -> FileIdentity? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileIdentity(stat: st)
    }

    /// Read `url`'s ENTIRE contents from ONE opened descriptor, verifying THAT descriptor's own
    /// fstat (dev, ino, size, mtime ns) against `expected` BEFORE reading and AGAIN AFTER
    /// readToEnd() (review6 finding 1: an in-place writer active DURING the read can yield torn
    /// bytes that a single pre-read fstat cannot see — the writer moves size/mtime, so the
    /// post-read fstat on the same descriptor catches it), and — when `expected` carries a
    /// digest — recomputing the digest over the bytes actually read and comparing.
    /// This is the consumer end of the watcher's single-descriptor chain: stat, completeness,
    /// digest (watcher) and the consumed bytes (here) all refer to the same file identity, or
    /// `FileIdentityMismatchError` is thrown and the caller skips the frame honestly.
    /// `expected == nil` → plain path read, unchanged legacy behavior for producers that carry
    /// no identity.
    public static func read(url: URL, verifying expected: FileIdentity?) throws -> Data {
        guard let expected else { return try Data(contentsOf: url) }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var st = Darwin.stat()
        guard fstat(fh.fileDescriptor, &st) == 0, expected.matches(stat: st) else {
            throw FileIdentityMismatchError(fileName: url.lastPathComponent)
        }
        // Read from the verified descriptor — never a separate reopen by path.
        let data = try fh.readToEnd() ?? Data()
        // Post-read revalidation: the identity must STILL hold after the bytes were read, or a
        // writer touched the file mid-read and `data` may be torn.
        var after = Darwin.stat()
        guard fstat(fh.fileDescriptor, &after) == 0, expected.matches(stat: after) else {
            throw FileIdentityMismatchError(fileName: url.lastPathComponent)
        }
        if let want = expected.digest, contentDigest(data: data) != want {
            throw FileIdentityMismatchError(fileName: url.lastPathComponent)
        }
        return data
    }

    // MARK: Content digest (shared producer/consumer definition)
    //
    // Strict content identity (review6 finding 2): FULL-FILE streaming SHA-256 over size + every
    // byte. The former head/tail sample let a middle-only change pass consumer validation AND be
    // wrongly deduped by the watcher — and for 64–128 KB files the tail was not hashed at all.
    // Two forms that MUST agree byte-for-byte (pinned by
    // testContentDigest_handleAndDataFormsAgree): the handle form streams 64 KB chunks so the
    // watcher never loads whole files; the data form hashes bytes a consumer already has in hand.
    // The size prefix is retained (redundant with full content, but keeps digests distinct from
    // any bare-SHA-256 use and both forms trivially aligned).

    static let digestChunk = 65_536

    /// Digest over in-memory bytes (consumer side — the bytes were just loaded anyway).
    public static func contentDigest(data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(data.count)".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digest over an open descriptor (producer side — streams 64 KB chunks to EOF, never loads
    /// the whole file). Returns nil when the handle cannot be read/seeked — the caller must skip
    /// the file rather than emit (a wrong digest would defeat dedupe and yield repeats).
    static func contentDigest(handle: FileHandle, size: Int) -> String? {
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: digestChunk) }
            catch { return nil }                        // read failure → skip the file
            guard let chunk, !chunk.isEmpty else { break }   // nil or empty → EOF
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A file no longer matches the identity its producer validated — the consumer must skip the
/// frame (honest log, never the session) rather than decode a replaced/truncated file.
public struct FileIdentityMismatchError: Error, CustomStringConvertible, Equatable {
    public let fileName: String
    public init(fileName: String) { self.fileName = fileName }
    public var description: String { "file changed between validation and read (\(fileName))" }
}

public struct StackUpdate: Equatable, Sendable {
    public let url: URL
    public let fileSize: Int
    /// Identity (incl. content digest) of the exact file version the watcher validated —
    /// captured from the watcher's pinned per-file descriptor. nil when the producer cannot
    /// supply one (compat); consumers then read by path, unchanged.
    public let identity: FileIdentity?

    public init(url: URL, fileSize: Int, identity: FileIdentity? = nil) {
        self.url = url
        self.fileSize = fileSize
        self.identity = identity
    }
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

    /// Per-file state for stability + dedupe. Stability tracks the FULL file identity
    /// (dev, ino, size, mtime at ns precision — digest nil at this stage) so a
    /// preallocated-but-still-filling FITS (full size, advancing mtime) is not emitted early,
    /// and a same-name REPLACEMENT (new inode) re-earns stability even when its (size, mtime)
    /// happen to match the old file's last observation.
    private var lastSeenStat: [String: FileIdentity] = [:]
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
            handleFolderReplaced()
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

            // ONE pinned descriptor per candidate file (review5 item 1). Everything the WATCHER
            // DECIDES with — the (size, mtime) stability observation via fstat(fd), the FITS
            // header + header-declared-size completeness check, the content digest, and the
            // identity attached to the emitted update — comes from THIS descriptor, opened
            // fd-relative to the pinned directory (never by path) BEFORE any stat. A swap
            // landing after the open can therefore never mix observations of two different
            // files (previously the OLD inode's size gated the completeness of a truncated NEW
            // replacement read by path). openat failure (ENOENT — the entry vanished since
            // enumeration; ELOOP — a symlinked entry, refused by O_NOFOLLOW) skips the file
            // this tick, exactly like a failed stat before.
            guard let handle = Self.openFile(directoryFD: folderFD, name: name) else { continue }
            // Exactly-once close on every path out of this iteration: this explicit close pairs
            // with closeOnDealloc as a backstop (FileHandle tracks closed state — no double close).
            defer { try? handle.close() }

            guard let observed = Self.statFile(handle), observed.size > 0 else { continue }

            let previous = lastSeenStat[name]
            lastSeenStat[name] = observed

            // Stability gate (P1-2): require the identity (dev, ino, size, mtime ns) unchanged
            // across two consecutive scans for BOTH file kinds. A writer that preallocates the
            // full declared size and then fills pixels in place satisfies size>=declared on the
            // first sighting; the stability requirement holds it back until the in-place writes
            // stop. A same-name replacement (new inode) re-earns stability from scratch.
            guard previous == observed else { continue }

            if isFITS {
                // Bulletproof completeness: header declares exact expected data length (spec §5.2),
                // and BOTH sides of the comparison come from the pinned descriptor — the header
                // bytes and the fstat size describe the same inode. Combined with the stability
                // gate above, this rejects both truncated files (size<declared) and
                // preallocated-but-unfilled files (stable check).
                guard let head = try? Self.readHead(handle, bytes: Self.maxHeaderBlocks * FITSReader.blockSize),
                      let header = try? FITSReader.readHeader(head),
                      observed.size >= header.minimumFileSize else { continue }
            }

            guard let digest = FileIdentity.contentDigest(handle: handle, size: observed.size)
            else { continue }

            // Final revalidation on the pinned descriptor (review6 finding 1): the header/
            // completeness read and the digest read above take time, and an in-place writer
            // active DURING them moves size/mtime — the digest would then describe torn bytes.
            // Require the identity unchanged from the initial fstat; otherwise treat the file as
            // unstable this tick (record the latest clean observation, no emit, no dedup update,
            // no log spam) and let it re-earn stability on later ticks.
            guard let finalStat = Self.statFile(handle) else { continue }
            guard finalStat == observed else {
                lastSeenStat[name] = finalStat
                continue
            }

            guard lastEmittedDigest[name] != digest else { continue }

            // Yield-time revalidation (review5 item 1): the emitted URL is still a PATH the
            // consumer resolves later, so before publishing, re-check that the watched path still
            // resolves to the directory this scan pinned. If it was swapped mid-scan, do NOT emit
            // a path that now names a different directory's file — trigger the same replacement
            // handling as the top-of-scan check (the next tick re-arms and rescans) and stop.
            // The residual consumer-side race (path re-resolved at read time) is closed by the
            // identity carried on the update: consumers verify (dev, ino, size, mtime, digest)
            // on THEIR OWN descriptor via FileIdentity.read(url:verifying:) before decoding.
            guard let armed = armedIdentity, Self.nodeIdentity(atPath: folder.path) == armed else {
                handleFolderReplaced()
                return
            }
            lastEmittedDigest[name] = digest
            continuation.yield(StackUpdate(
                url: url, fileSize: observed.size,
                identity: observed.withDigest(digest)))
        }
    }

    /// Mid-tick folder replacement handling — shared by the top-of-scan identity check and the
    /// yield-time revalidation: log honestly, drop the stale source, clear PENDING stability
    /// observations (emitted digests RETAINED for dedup), and mark missing so the next tick
    /// re-arms via the recovery branch.
    private func handleFolderReplaced() {
        onLog?("watched folder was replaced — re-arming: \(folder.path)")
        cancelSource()
        lastSeenStat.removeAll()
        folderMissing = true
    }

    /// Open ONE read descriptor for a directory entry, resolved RELATIVE to the pinned directory
    /// fd — never by path (review5 item 1). O_NOFOLLOW refuses symlinked entries. Returns nil on
    /// any open failure (the caller skips the file this tick). The returned FileHandle OWNS the
    /// descriptor (closeOnDealloc), so close happens exactly once on every path.
    ///
    /// Internal (not private) so the structural single-descriptor property is directly
    /// unit-testable (see testOpenFile_pinnedDirectoryFDReadsOldFileAcrossAtomicSwap).
    static func openFile(directoryFD: Int32, name: String) -> FileHandle? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// fstat(2) the open descriptor — size + mtime for the stability gate, (dev, ino) for the
    /// emitted identity. Internal for the same testability reason as `openFile`.
    static func statFile(_ handle: FileHandle) -> FileIdentity? {
        var st = Darwin.stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
        return FileIdentity(stat: st)
    }

    /// Read the header prefix from the pinned per-file descriptor (seeks to 0 first — the
    /// descriptor is reused across the header and digest reads).
    private static func readHead(_ handle: FileHandle, bytes: Int) throws -> Data {
        try handle.seek(toOffset: 0)
        // FileHandle.read returning nil is a framework-level anomaly; the empty-Data
        // fallback yields a truncated-header skip in scan(), which is safe.
        return try handle.read(upToCount: bytes) ?? Data()
    }
}
