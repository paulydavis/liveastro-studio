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
    /// the file rather than emit (a wrong digest would defeat dedupe and yield repeats) — or
    /// when `shouldAbort` reports true between chunks (review10 item 3: a bounded stop() must
    /// not wait behind a full-file hash stalled on a dead share; an aborted digest is
    /// skip-this-tick semantics, never a wrong digest).
    static func contentDigest(handle: FileHandle, size: Int,
                              shouldAbort: (() -> Bool)? = nil) -> String? {
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        while true {
            if shouldAbort?() == true { return nil }    // bounded-stop abort between chunks
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

/// Lifecycle misuse of a StackFileWatcher (review9 item 4). The watcher is ONE-SHOT:
/// initial → running (successful start) → stopped (terminal). A failed initial start
/// stays retryable; everything else fails explicitly instead of silently overwriting
/// live sources/timers or resurrecting a stopped watcher.
public enum StackFileWatcherError: Error, Equatable {
    /// start() while already running — the live source/timer must never be overwritten.
    case alreadyStarted
    /// start() after stop() — stopped is terminal; construct a new watcher instead.
    case stopped
}

/// Watches a folder for completed writes of stack images.
/// Siril rewrites live_stack.fit in place, so this is modification-watching with
/// write-completion checks, not new-file detection (spec §5.2).
public final class StackFileWatcher {

    /// How the watcher treats content hashing for files it has ALREADY emitted
    /// (review7 P2). Chosen by the CONSTRUCTING code path — never user
    /// configuration — because the right policy is a property of the producer
    /// writing the folder.
    public enum DigestPolicy: Sendable {
        /// Files are immutable once published (native relay folders: every sub
        /// is written once and never touched again). An already-emitted
        /// identity (dev, ino, size, mtime-ns) is trusted to imply unchanged
        /// content and is NEVER re-hashed — each poll costs one fstat per file
        /// instead of a full SHA-256 of every file in the folder (at 1000
        /// accumulated subs the old full rehash burned tens of seconds of
        /// hashing per 2 s scan).
        case immutableAfterPublish
        /// The producer rewrites its output in place (Siril's live_stack.fit).
        /// Identity is NOT trusted to imply unchanged content: coarse or cached
        /// filesystem timestamps can leave (dev, ino, size, mtime-ns) identical
        /// across a real content change, so every stable sighting is fully
        /// re-hashed (exactly the pre-review7 strictness) and dedup happens on
        /// the digest alone. A NEW digest additionally passes the
        /// digest-stability gate (review8 finding 1): it is emitted only after
        /// the SAME digest is observed again at least `quietPeriod` of
        /// monotonic time later — one extra poll tick of latency per
        /// live_stack update, in exchange for not publishing a mid-rewrite
        /// pause's temporary A/B hybrid.
        case mutableStackerOutput
    }

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

    // MARK: Lifecycle (review9 item 4)
    //
    // All lifecycle state — `state`, the sources/timer/debounce references, the fd — is
    // QUEUE-CONFINED: start()/stop() and the synchronized accessors hop onto the watcher
    // queue instead of mutating queue-owned state from the caller thread. The hop is
    // REENTRANCY-SAFE: a DispatchSpecificKey identifies the watcher queue, so a callback
    // already running on it (an onLog handler invoking stop(), a test seam) executes the
    // body inline rather than deadlocking through queue.sync.

    /// One-shot state machine: initial → running (successful start) → stopped (terminal).
    /// A FAILED initial start leaves the watcher in `.initial` — retryable.
    private enum LifecycleState { case initial, running, stopped }
    private var state: LifecycleState = .initial

    /// Review10 item 3: one-way stop request, set by stop() BEFORE any queue hop and
    /// therefore visible to an IN-FLIGHT scan immediately (state itself is queue-confined
    /// and only flips to .stopped when the queued teardown runs — which a stalled scan
    /// delays). The scan polls this at per-file boundaries, between 64 KB digest chunks
    /// (via the shouldAbort closure), and immediately before yielding, so a stop landing
    /// mid-scan aborts the scan without emitting even while `state` still reads .running.
    private let stopRequested = NSLock_Flag()

    /// Identifies the watcher queue for reentrancy detection (value set in init).
    private let queueKey = DispatchSpecificKey<Bool>()

    /// Run `body` on the watcher queue: inline when already there, queue.sync otherwise.
    private func onQueueSync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

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
    /// would apply old-generation observations to the NEW directory's files. Enumerating through
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

    /// Count of full content digests computed by this watcher (review7 P2) —
    /// test-visible so the hashing cost model is pinned: flat after emission
    /// under `.immutableAfterPublish` (and for emitted numbered revisions under
    /// `.mutableStackerOutput`), growing per stable scan for the classic
    /// in-place file. Mutated only on the internal serial queue; the storage is
    /// private and exposed through the queue-synchronized snapshot below.
    private var _digestComputations: Int = 0
    /// Queue-synchronized snapshot of `_digestComputations` (review9 item 6):
    /// tests may read it while the repeating timers are live — the read hops
    /// through the reentrancy-safe sync, so it never races the queue-confined
    /// writes in scan().
    internal var digestComputations: Int { onQueueSync { _digestComputations } }

    /// Monotonic now, in nanoseconds (review8 finding 1). DispatchTime rides
    /// CLOCK_UPTIME_RAW — never wall-adjusted, never goes backwards — which is
    /// what the digest-stability gate's separation requirement needs (Date/
    /// wall-clock can jump). Injectable for tests ONLY: a manual clock lets the
    /// quiet-period separation be exercised without wall-clock sleeps. Read on
    /// the internal serial queue; tests install it before start().
    internal var monotonicNowNanos: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    /// Run ONE synchronous scan on the watcher's serial queue (test seam, same
    /// internal-for-testability rationale as `enumerateDirectory`/`openFile`).
    /// Tests park the debounce and poll timer on huge intervals and call this
    /// to choreograph exact scan sequences deterministically. Production code
    /// never calls it.
    internal func scanNow() { onQueueSync { scan() } }

    private let fileNamePrefix: String?

    /// The reducer is the sole semantic state owner once scan integration is complete.
    private var reducer: WatcherReducer

    /// Deterministic integration seam: tests may replace the watched folder after a complete
    /// observation batch has reduced, but before its ordered effects execute.
    internal var afterObservationBatchForTesting: (() -> Void)?

    /// Queue-confined reducer snapshot for integration assertions. Internal test access only.
    internal var reducerStateSnapshot: WatcherState { onQueueSync { reducer.state } }

    /// Test-visible timing values remain at the watcher boundary, sourced from reducer config.
    internal var blockingBudgetNanos: UInt64 { reducer.blockingBudgetNanos }
    internal var blockingGraceNanos: UInt64 { reducer.blockingGraceNanos }
    internal var blockingCeilingNanos: UInt64 { reducer.blockingCeilingNanos }

    private static let maxHeaderBlocks = 32  // generous ceiling; real headers are 1-10 blocks

    /// Review10 item 7: `quietPeriod`/`pollInterval` are public Doubles that feed reducer
    /// nanosecond configuration and DispatchTime arithmetic — a
    /// negative, NaN, infinite, or huge value trapped there at scan/schedule time. Sanitize
    /// at the construction boundary instead: non-finite values take the documented default;
    /// finite values clamp into [0.01 s, 3600 s].
    private static func sanitizedInterval(_ value: TimeInterval,
                                          default def: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return def }
        return min(max(value, 0.01), 3600)
    }

    public init(folder: URL, quietPeriod: TimeInterval = 0.5, pollInterval: TimeInterval = 2.0,
                fileNamePrefix: String? = nil,
                digestPolicy: DigestPolicy = .mutableStackerOutput) {
        self.folder = folder
        // Review10 item 7: hostile timing values are clamped/defaulted, never trusted into
        // UInt64/DispatchTime conversions (see sanitizedInterval).
        self.quietPeriod = Self.sanitizedInterval(quietPeriod, default: 0.5)
        self.pollInterval = Self.sanitizedInterval(pollInterval, default: 2.0)
        self.fileNamePrefix = fileNamePrefix
        self.reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 0),
                    files: [:],
                    ordering: RevisionOrderingState(activeBlocker: nil)),
                lastEmittedDigestByName: [:]),
            configuration: WatcherReducerConfiguration(
                digestPolicy: digestPolicy,
                filePrefix: fileNamePrefix,
                quietPeriodNanos: UInt64((self.quietPeriod * 1_000_000_000).rounded()),
                pollIntervalNanos: UInt64((self.pollInterval * 1_000_000_000).rounded())))
        queue.setSpecific(key: queueKey, value: true)
        var cont: AsyncStream<StackUpdate>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Fallback for an owner that drops a started watcher without stop() (review9 item 4):
    /// the one-shot guard alone would leak the armed folder fd and leave the sources/timer
    /// scheduled. deinit can only run when no queued block holds a strong reference (every
    /// handler captures self weakly), so `state` is safe to read without the queue hop —
    /// which could deadlock anyway if the last release happened ON the watcher queue.
    /// Source/timer cancellation is thread-safe, and the source's cancel handler (which
    /// closes the fd) captures only the fd, never self.
    deinit {
        guard state == .running else { return }
        debounceWork?.cancel()
        source?.cancel()
        pollTimer?.cancel()
        continuation.finish()
    }

    public func start() throws {
        try onQueueSync {
            switch state {
            case .running: throw StackFileWatcherError.alreadyStarted
            case .stopped: throw StackFileWatcherError.stopped
            case .initial: break
            }
            try armSource()   // a throw here leaves state == .initial — retryable

            // Poll fallback: catches events DispatchSource misses (network volumes, in-place
            // mmap writes). The timer keeps running even while the folder is missing — it's
            // what detects the return.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            pollTimer = timer
            state = .running
        }
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

    /// Stop the watcher with a BOUNDED wait (review10 item 3). The teardown itself stays
    /// queue-confined, but stop() no longer parks unboundedly behind an in-flight scan: a
    /// full-file hash stalled on a dead network share used to pin queue.sync — and
    /// SessionPipeline.end() behind it — indefinitely, outside every promised timeout.
    /// `stopRequested` is set FIRST (an atomic the scan polls at per-file boundaries,
    /// between digest chunks, and before yielding — it aborts without emitting), then the
    /// queue-confined teardown is enqueued and awaited up to `timeout` seconds. On expiry
    /// stop() logs honestly and returns: the descriptors still close via the sources'
    /// cancel/deinit paths once the abandoned scan yields, that scan observes the stop flag
    /// at its next check and exits without emitting, and the queued teardown then runs.
    /// The timeout log line is the ONE onLog delivery made from the caller's thread rather
    /// than the watcher queue — on this path the queue is, by definition, stalled.
    public func stop(timeout: TimeInterval = 5.0) {
        stopSeamLock.withLock { _lastStopTimeout = timeout }
        stopRequested.set()
        // Reentrant call (an onLog handler running ON the watcher queue invoking stop()):
        // run the teardown inline — waiting for our own queue would deadlock.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            teardown()
            return
        }
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.teardown()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            onLog?("watcher stop timed out behind a stalled read — abandoning the scan; descriptors close via cancel handlers")
        }
    }

    /// Test seam (cold2 M3, mirroring FolderFrameSource's): the timeout the most recent
    /// stop() ran with — pins budget threading without wall-clock assertions.
    /// Lock-guarded: stop() may be called from any thread.
    private let stopSeamLock = NSLock()
    private var _lastStopTimeout: TimeInterval?
    internal var lastStopTimeout: TimeInterval? { stopSeamLock.withLock { _lastStopTimeout } }

    /// Queue-confined terminal teardown (the body of the pre-review10 stop()).
    private func teardown() {
        guard state != .stopped else { return }   // idempotent
        // Terminal state FIRST (review9 item 4): any reentrant callback fired during
        // the teardown below observes .stopped immediately and no-ops — no re-arm, no
        // emit, no re-scheduled scan.
        state = .stopped
        debounceWork?.cancel(); debounceWork = nil
        // The fd is closed by the source's cancel handler, never here (see armSource()).
        cancelSource()
        pollTimer?.cancel(); pollTimer = nil
        continuation.finish()
    }

    private func scheduleScan() {
        guard state == .running else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    private func scan() {
        // A queued/debounced scan may outlive stop(). The atomic flag also covers a stop whose
        // queue-confined teardown is waiting behind this scan.
        guard state == .running, !stopRequested.isSet else { return }
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        let nodeExists = fm.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        let folderExists = nodeExists && isDirectory.boolValue
        if !folderExists {
            if !folderMissing {
                folderMissing = true
                onLog?("watched folder disappeared — waiting for it to return: \(folder.path)")
                cancelSource()
                replaceGeneration()
            }
            if nodeExists {
                if !nonDirectoryAtPathLogged {
                    nonDirectoryAtPathLogged = true
                    onLog?("watched path exists but is not a directory — still waiting for a directory: \(folder.path)")
                }
            } else {
                nonDirectoryAtPathLogged = false
            }
            return
        }
        nonDirectoryAtPathLogged = false

        if !folderMissing, let armed = armedIdentity,
           let current = Self.nodeIdentity(atPath: folder.path), current != armed {
            handleFolderReplaced()
        }

        if folderMissing {
            guard state == .running else { return }
            do {
                try armSource()
                replaceGeneration()
                onLog?("watched folder returned — resuming: \(folder.path)")
                folderMissing = false
                rearmFailed = false
            } catch {
                if !rearmFailed {
                    rearmFailed = true
                    onLog?("watched folder returned but re-arm failed — retrying on later polls: \(folder.path) (\(error))")
                }
            }
        }

        guard folderFD >= 0, let names = Self.enumerateDirectory(fd: folderFD) else { return }
        let trackedNames = reducer.orderedNamesForScan(names.filter(isTrackedFileName))
        var observations: [FileObservation] = []
        observations.reserveCapacity(trackedNames.count + reducer.state.generation.files.count)

        for name in trackedNames {
            if stopRequested.isSet { return }
            guard let observation = observeFile(named: name) else { return }
            observations.append(observation)
        }

        let present = Set(trackedNames)
        let absentNames = reducer.orderedNamesForScan(
            reducer.state.generation.files.keys.filter { !present.contains($0) })
        observations.append(contentsOf: absentNames.map { name in
            FileObservation(
                name: name,
                url: folder.appendingPathComponent(name),
                kind: reducer.entryKind(for: name),
                outcome: .absent)
        })

        let nowNanos = monotonicNowNanos()
        guard state == .running, !stopRequested.isSet else { return }
        let effects = reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: observations,
            nowNanos: nowNanos)))
        afterObservationBatchForTesting?()
        execute(effects)
    }

    private func isTrackedFileName(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { return false }
        if let prefix = fileNamePrefix, !prefix.isEmpty,
           !name.lowercased().hasPrefix(prefix.lowercased()) { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ImageLoader.fitsExtensions.contains(ext)
            || ImageLoader.bitmapExtensions.contains(ext)
    }

    /// Build exactly one immutable observation from one pinned descriptor. A nil return means
    /// the streaming digest observed stopRequested and the entire scan must abort.
    private func observeFile(named name: String) -> FileObservation? {
        let url = folder.appendingPathComponent(name)
        let invalid: (String) -> FileObservation = { reason in
            FileObservation(
                name: name,
                url: url,
                kind: self.reducer.entryKind(for: name),
                outcome: .invalid(reason: reason))
        }

        guard let handle = Self.openFile(directoryFD: folderFD, name: name) else {
            return invalid("open failed or entry is not a regular file")
        }
        defer { try? handle.close() }

        guard let observed = Self.statFile(handle), observed.size > 0 else {
            return invalid("stat failed or file is empty")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let entry = EnumeratedEntry(
            name: name,
            url: url,
            identity: observed,
            isFITS: ImageLoader.fitsExtensions.contains(ext))
        guard let request = reducer.readPlan(for: [entry]).first else {
            return invalid("no read plan")
        }

        switch request {
        case .acceptIdentity(let observation):
            return observation

        case .observeWithoutContent(let observation):
            return observation

        case .readContent(let requestName, let requestURL, let kind,
                          let identity, let isFITS):
            if isFITS {
                guard let head = try? Self.readHead(
                    handle, bytes: Self.maxHeaderBlocks * FITSReader.blockSize),
                      let header = try? FITSReader.readHeader(head),
                      identity.size >= header.minimumFileSize else {
                    return FileObservation(
                        name: requestName,
                        url: requestURL,
                        kind: kind,
                        outcome: .invalid(reason: "malformed or incomplete FITS"))
                }
            }

            _digestComputations += 1
            let stopFlag = stopRequested
            guard let digest = FileIdentity.contentDigest(
                handle: handle,
                size: identity.size,
                shouldAbort: { stopFlag.isSet }) else {
                if stopRequested.isSet { return nil }
                return FileObservation(
                    name: requestName,
                    url: requestURL,
                    kind: kind,
                    outcome: .invalid(reason: "digest failed"))
            }

            guard let finalStat = Self.statFile(handle) else {
                return FileObservation(
                    name: requestName,
                    url: requestURL,
                    kind: kind,
                    outcome: .invalid(reason: "final stat failed"))
            }
            guard finalStat == identity else {
                return FileObservation(
                    name: requestName,
                    url: requestURL,
                    kind: kind,
                    outcome: .unstable(identity: finalStat))
            }
            return FileObservation(
                name: requestName,
                url: requestURL,
                kind: kind,
                outcome: .digested(
                    identity: identity,
                    digest: digest,
                    byteCount: identity.size))
        }
    }

    private func execute(_ effects: [WatcherEffect]) {
        for effect in effects {
            switch effect {
            case .log(let message):
                onLog?(message)

            case .emit(let intent):
                guard reducer.shouldExecuteEmission(intent) else {
                    let followupEffects = reducer.reduce(.emissionFinished(EmissionResult(
                        intent: intent,
                        outcome: .rejected)))
                    execute(followupEffects)
                    continue
                }
                guard let armed = armedIdentity,
                      Self.nodeIdentity(atPath: folder.path) == armed else {
                    handleFolderReplaced()
                    _ = reducer.reduce(.emissionFinished(EmissionResult(
                        intent: intent,
                        outcome: .rejected)))
                    return
                }
                guard state == .running, !stopRequested.isSet else {
                    _ = reducer.reduce(.emissionFinished(EmissionResult(
                        intent: intent,
                        outcome: .rejected)))
                    return
                }
                continuation.yield(StackUpdate(
                    url: intent.candidate.url,
                    fileSize: intent.candidate.byteCount,
                    identity: intent.candidate.identity.withDigest(intent.candidate.digest)))
                let followupEffects = reducer.reduce(.emissionFinished(EmissionResult(
                    intent: intent,
                    outcome: .yielded)))
                execute(followupEffects)
            }
        }
    }

    private func replaceGeneration() {
        let current = reducer.state.generation.id.rawValue
        precondition(current < UInt64.max, "watcher folder generation exhausted")
        _ = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: current + 1)))
    }

    /// Mid-tick replacement handling shared by the top-of-scan and pre-yield identity checks.
    /// Whole-generation replacement retains only the reducer's content-bound digest table.
    private func handleFolderReplaced() {
        onLog?("watched folder was replaced — re-arming: \(folder.path)")
        cancelSource()
        replaceGeneration()
        folderMissing = true
    }

    /// Open ONE read descriptor for a directory entry, resolved RELATIVE to the pinned directory
    /// fd — never by path (review5 item 1). O_NOFOLLOW refuses symlinked entries. Returns nil on
    /// any open failure (the caller skips the file this tick). The returned FileHandle OWNS the
    /// descriptor (closeOnDealloc), so close happens exactly once on every path.
    ///
    /// Review9 item 3: the open is NON-BLOCKING and the descriptor must prove S_IFREG before it
    /// is accepted. A blocking O_RDONLY open of a FIFO with no writer (`mkfifo blocked.fit`)
    /// parks openat on the ONLY watcher queue forever — no later file, no recovery, no stop().
    /// O_NONBLOCK makes the FIFO open return immediately; the fstat then rejects every
    /// non-regular node (FIFO, socket, device, directory) silently, exactly like any other
    /// per-file failure. For accepted regular files O_NONBLOCK is cleared again via
    /// fcntl(F_SETFL): regular-file reads ignore the flag on macOS anyway, but the handle feeds
    /// the streamed header/digest reads — keep its semantics explicitly blocking rather than
    /// lean on that platform behavior.
    ///
    /// Internal (not private) so the structural single-descriptor property is directly
    /// unit-testable (see testOpenFile_pinnedDirectoryFDReadsOldFileAcrossAtomicSwap).
    static func openFile(directoryFD: Int32, name: String) -> FileHandle? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)   // not a regular file — skip silently this tick
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
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
