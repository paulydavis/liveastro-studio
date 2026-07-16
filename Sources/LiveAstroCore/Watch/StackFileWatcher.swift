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
    /// `quietPeriod` in nanoseconds — the digest-stability gate's minimum monotonic
    /// separation between the two observations of a new digest (review8 finding 1).
    private var quietPeriodNanos: UInt64 { UInt64((quietPeriod * 1_000_000_000).rounded()) }
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

    /// Digest-stability gate state (review8 finding 1, `.mutableStackerOutput`
    /// only): a NEW digest observed on a stat-stable file, the stat identity it
    /// was observed under, and WHEN it was first observed (monotonic ns). The
    /// digest is emitted only once a later scan observes the SAME digest under
    /// the SAME stat identity at least `quietPeriod` later — the two-tick stat
    /// philosophy mirrored at the content level. The gate restarts whenever the
    /// digest changes, the stat identity changes, or the folder generation
    /// changes (disappear/replace/re-arm — cleared with the pending stat map).
    private struct PendingContent {
        let digest: String
        let identity: FileIdentity
        let firstObservedNanos: UInt64
    }
    private var pendingContent: [String: PendingContent] = [:]
    /// Stat identity (digest nil) of the version whose digest currently sits in
    /// `lastEmittedDigest[name]` (review7 P2). Under `.immutableAfterPublish`,
    /// a candidate whose observed identity equals this entry skips ALL content
    /// work. CLEARED on every folder disappear/replace/re-arm (review8 finding
    /// 2) — the asymmetry with `lastEmittedDigest` is deliberate: identities
    /// are LOCATION-BOUND and die with the folder generation (a remounted
    /// share or reused inode can reproduce the same dev/ino/size/cached
    /// mtime-ns for different bytes, which would silently suppress a genuinely
    /// new sub), while digests are CONTENT-BOUND and survive it (dedup stays
    /// safe). The cost is one rehash per file after a reconnect — the honest
    /// price of not trusting a dead generation's identities.
    private var lastEmittedIdentity: [String: FileIdentity] = [:]

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
    private let digestPolicy: DigestPolicy

    // MARK: Revision order gate (review10 item 1)
    //
    // The review9 sort makes emission order deterministic WITHIN one scan, but revisions
    // earn their gates independently ACROSS scans: an incomplete _00001 (unstable, mid
    // digest-gate, invalid) was skipped while a complete _00002 emitted, and _00001 then
    // emitted on a later scan — the consumer saw [2, 1] and the replay regressed. Two
    // rules close this, both riding the single numericCompare comparator:
    //  (a) HOLDBACK — within a scan, once a numbered revision is found NOT yet emittable,
    //      no higher-numbered revision emits this scan; a held revision keeps its gate
    //      evidence and emits as soon as the blocker clears. Non-numbered entries sort
    //      before the revision series and are unaffected.
    //  (b) REJECT BELOW THE MARK — a never-emitted numbered revision at or below the
    //      high-water mark of emitted revisions arrived out of order and is dropped
    //      permanently with one honest log line: the FRAME is lost, the session preserved
    //      (the invariant), and the consumer's replay never regresses.

    /// Highest numbered revision EMITTED this folder generation (digit string, compared
    /// with numericCompare). Advanced at emission — the single point revisions become
    /// consumer-visible — and cleared with the per-generation state on folder
    /// disappear/replace. Emitted DIGESTS survive generations (dedup stays content-bound);
    /// the mark governs ORDER only.
    private var emittedRevisionHighWater: String?

    /// Names already dropped+logged as out-of-order this folder generation, so the honest
    /// drop line fires once per file, not on every poll tick while the file sits there.
    private var outOfOrderDropLogged: Set<String> = []

    // MARK: Numbered-revision parser (review9 items 1+2)
    //
    // The SINGLE source of truth for both CLASSIFYING a numbered stacker revision
    // (`<prefix>_(\d+).<ext>` — Siril 1.4+ writes live_stack_00001.fit, live_stack_00002.fit, …
    // once each and never rewrites them) and ORDERING candidates. Anchored
    // `^<escapedPrefix>_(\d+)\.<ext>$` semantics: the user-supplied prefix is DATA, not
    // pattern (escaped), the whole match is case-insensitive (mirroring the prefix filter in
    // scan()), and the extension must belong to the supported image sets. The captured
    // revision stays a DIGIT STRING with numeric-aware comparison (length, then
    // lexicographic) — never an Int conversion, so a 30-digit suffix classifies and sorts
    // identically instead of overflowing into a different path.

    /// Compiled once per watcher from the configured prefix; nil when no prefix is set
    /// (no prefix → no revision series to recognize; every candidate is non-numbered).
    private let revisionRegex: NSRegularExpression?

    /// The digit-string revision of `name` when it is a numbered revision of the configured
    /// prefix (supported image extension required); nil for everything else — including the
    /// classic fixed-name file (`live_stack.fit`) and near-misses like
    /// `live_stack_extra_00001.fit`, which conservatively keep full mutable-policy re-hashing.
    private func revisionSuffix(of name: String) -> String? {
        guard let regex = revisionRegex else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let m = regex.firstMatch(in: name, options: [], range: range),
              let digitsRange = Range(m.range(at: 1), in: name),
              let extRange = Range(m.range(at: 2), in: name) else { return nil }
        let ext = name[extRange].lowercased()
        guard ImageLoader.fitsExtensions.contains(ext) || ImageLoader.bitmapExtensions.contains(ext)
        else { return nil }
        return String(name[digitsRange])
    }

    /// Numeric order for digit strings without Int conversion (review10 item 6): leading
    /// zeros are numerically insignificant, so they are stripped before the shorter-is-
    /// smaller / lexicographic-on-equal-length comparison — the former RAW-length compare
    /// sorted "10" before "002". Equal numeric VALUES with different padding ("007" vs "7")
    /// tie-break on the raw string, so this stays a stable total order.
    private static func digitStringLess(_ a: String, _ b: String) -> Bool {
        switch numericCompare(a, b) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       return a < b
        }
    }

    /// Numeric comparison of two digit strings with leading zeros stripped (an all-zeros
    /// string strips to the empty suffix, which behaves as "0"). The ONE comparator behind
    /// candidate ordering AND the emitted-revision high-water mark (review10 items 1+6) —
    /// classification, ordering, and the order gate can never disagree.
    private static func numericCompare(_ a: String, _ b: String) -> ComparisonResult {
        let na = a.drop { $0 == "0" }, nb = b.drop { $0 == "0" }
        if na.count != nb.count { return na.count < nb.count ? .orderedAscending : .orderedDescending }
        if na == nb { return .orderedSame }
        return na < nb ? .orderedAscending : .orderedDescending
    }

    /// Deterministic candidate order (review9 item 2): readdir order is POSIX-undefined, and
    /// several revisions accumulating during a reconnect must replay in NUMERIC order — not
    /// _00010 → _00008 → _00009, which visually regresses the replay. Numbered revisions sort
    /// numerically (digit-string compare, full-name tiebreak); non-numbered names sort
    /// lexicographically and BEFORE the revision series. Ties are impossible (names are
    /// unique + full-name tiebreak), so this is a total order — no reliance on sort stability.
    private static func orderedBefore(_ a: (name: String, revision: String?),
                                      _ b: (name: String, revision: String?)) -> Bool {
        switch (a.revision, b.revision) {
        case let (ra?, rb?): return ra == rb ? a.name < b.name : digitStringLess(ra, rb)
        case (nil, nil):     return a.name < b.name
        case (nil, .some):   return true
        case (.some, nil):   return false
        }
    }

    private static let maxHeaderBlocks = 32  // generous ceiling; real headers are 1-10 blocks

    /// Review10 item 7: `quietPeriod`/`pollInterval` are public Doubles that feed an
    /// unchecked UInt64 conversion (`quietPeriodNanos`) and DispatchTime arithmetic — a
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
        self.digestPolicy = digestPolicy
        if let prefix = fileNamePrefix, !prefix.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            // The pattern is built from escaped data + fixed syntax; it cannot fail to
            // compile, but a nil regex would only mean "no numbered revisions recognized" —
            // strictly more conservative (full re-hash), never wrong.
            self.revisionRegex = try? NSRegularExpression(
                pattern: "^\(escaped)_([0-9]+)\\.([^.]+)$", options: [.caseInsensitive])
        } else {
            self.revisionRegex = nil
        }
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
        // Review9 item 4: a scan parked across stop() (debounced work, a queued poll tick,
        // a test-seam replay) must observe the terminal state and no-op — never re-arm or
        // emit. Review10 item 3: the atomic stop flag covers the window where stop()'s
        // teardown is still queued behind earlier work and `state` has not flipped yet.
        guard state == .running, !stopRequested.isSet else { return }
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
                // Review8 finding 1: pending content observations belong to the folder
                // generation they were made in — the gate restarts after a return.
                pendingContent.removeAll()
                // Review8 finding 2: the identity FAST-PATH dies with the folder
                // generation — identities are location-bound (a remounted share or
                // reused inode can present the same dev/ino/size/cached mtime-ns for
                // different bytes), digests are content-bound and are retained above.
                lastEmittedIdentity.removeAll()
                // Review10 item 1: revision ORDER state is per-generation like the pending
                // maps. Emitted digests survive (above), so re-sightings of already-emitted
                // revisions still dedup; only the ordering gate restarts.
                emittedRevisionHighWater = nil
                outOfOrderDropLogged.removeAll()
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
            // Review9 item 4: a reentrant stop() (an onLog callback above — the disappearance
            // or replacement log — runs on this queue and may stop the watcher inline) must
            // prevent the re-arm below: re-arming after stop() is resurrection.
            guard state == .running else { return }
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
        // Review10 item 2: PENDING (unemitted) evidence for a file ABSENT this scan dies
        // now — a file that vanishes mid-gate and returns with a manufactured matching
        // identity must re-earn stability and the digest gate from zero, not resume off
        // observations of an entry that demonstrably stopped existing. Emitted digests and
        // identities are untouched: dedup governs re-emission, not pending evidence.
        let present = Set(names)
        if !lastSeenStat.isEmpty { lastSeenStat = lastSeenStat.filter { present.contains($0.key) } }
        if !pendingContent.isEmpty {
            pendingContent = pendingContent.filter { present.contains($0.key) }
        }
        // Review9 item 2: process candidates in a deterministic order (numbered revisions
        // numerically, everything else lexicographically — see orderedBefore). The revision
        // suffix is parsed ONCE per name here and reused for the per-entry policy below.
        let candidates = names.map { (name: $0, revision: revisionSuffix(of: $0)) }
            .sorted(by: Self.orderedBefore)
        // Review10 item 1 (HOLDBACK): true once a numbered revision in THIS scan proved not
        // yet emittable — every higher-numbered revision then advances its gates normally
        // but is not allowed to EMIT this scan (see the pre-emission check below).
        var holdRevisionsAbove = false
        for (name, revision) in candidates {
            // Review10 item 3: a stop() waiting out its bounded deadline sees this scan
            // yield at the next per-file boundary — never park behind the rest of the folder.
            if stopRequested.isSet { return }
            guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { continue }
            if let prefix = fileNamePrefix, !prefix.isEmpty,
               !name.lowercased().hasPrefix(prefix.lowercased()) { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let isFITS = ImageLoader.fitsExtensions.contains(ext)
            guard isFITS || ImageLoader.bitmapExtensions.contains(ext) else { continue }

            // Review10 item 1 (REJECT BELOW THE MARK): a never-emitted numbered revision at
            // or below the emitted high-water mark arrived out of order — emitting it now
            // would regress the consumer's replay. Drop the frame permanently, keep the
            // session, log once. Names that already emitted are exempt: their re-sightings
            // are governed by the identity fast-path and digest dedup below (the mark
            // governs ORDER, never re-emission).
            if let revision, lastEmittedDigest[name] == nil,
               let mark = emittedRevisionHighWater,
               Self.numericCompare(revision, mark) != .orderedDescending {
                if outOfOrderDropLogged.insert(name).inserted {
                    onLog?("revision \(revision) arrived out of order — skipped (high-water \(mark))")
                }
                continue
            }

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
            guard let handle = Self.openFile(directoryFD: folderFD, name: name) else {
                clearPendingEvidence(for: name)                    // review10 item 2
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: invalid
                continue
            }
            // Exactly-once close on every path out of this iteration: this explicit close pairs
            // with closeOnDealloc as a backstop (FileHandle tracks closed state — no double close).
            defer { try? handle.close() }

            guard let observed = Self.statFile(handle), observed.size > 0 else {
                clearPendingEvidence(for: name)                    // review10 item 2
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: invalid
                continue
            }

            let previous = lastSeenStat[name]
            lastSeenStat[name] = observed

            // Review7 P2 (identity-gated hashing): this exact published version — same
            // (dev, ino, size, mtime-ns) as the emission that produced
            // `lastEmittedDigest[name]` — was already emitted, so when the file is
            // trusted immutable AFTER emission, skip ALL content work: one fstat per
            // poll instead of a full-file SHA-256. That trust holds for every file
            // under `.immutableAfterPublish` (native relay folders accumulate every
            // sub; at 1000 subs the unconditional rehash burned tens of seconds per
            // 2 s scan), and — review9 item 1 — for NUMBERED REVISIONS under
            // `.mutableStackerOutput` (Siril 1.4+ writes live_stack_00001.fit once
            // and never rewrites it; without the fast-path, 1000 × 50 MB accumulated
            // revisions meant 50 GB hashed per 2 s scan, starving new updates).
            // Numbered revisions may be written NON-ATOMICALLY before publication,
            // so pre-emission they take the full mutable path — stat stability AND
            // the two-observation digest gate below — and only their CONFIRMED first
            // emission arms this shortcut: post-emission trust is the single
            // divergence point. The CLASSIC in-place fixed-name file (revision nil)
            // never takes the shortcut: a coarse/cached-filesystem rewrite can
            // collide the whole identity, and only the digest sees the change.
            let identityTrustedAfterEmission =
                digestPolicy == .immutableAfterPublish || revision != nil
            if identityTrustedAfterEmission,
               lastEmittedIdentity[name] == observed { continue }

            // Stability gate (P1-2): require the identity (dev, ino, size, mtime ns) unchanged
            // across two consecutive scans for BOTH file kinds. A writer that preallocates the
            // full declared size and then fills pixels in place satisfies size>=declared on the
            // first sighting; the stability requirement holds it back until the in-place writes
            // stop. A same-name replacement (new inode) re-earns stability from scratch.
            guard previous == observed else {
                // Review8 finding 1: a stat-identity change restarts the digest-stability
                // gate — a pending content observation is only meaningful under the exact
                // identity it was observed with.
                pendingContent[name] = nil
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: unstable
                continue
            }

            if isFITS {
                // Bulletproof completeness: header declares exact expected data length (spec §5.2),
                // and BOTH sides of the comparison come from the pinned descriptor — the header
                // bytes and the fstat size describe the same inode. Combined with the stability
                // gate above, this rejects both truncated files (size<declared) and
                // preallocated-but-unfilled files (stable check).
                guard let head = try? Self.readHead(handle, bytes: Self.maxHeaderBlocks * FITSReader.blockSize),
                      let header = try? FITSReader.readHeader(head),
                      observed.size >= header.minimumFileSize else {
                    clearPendingEvidence(for: name)                    // review10 item 2
                    if revision != nil { holdRevisionsAbove = true }   // review10 item 1: invalid
                    continue
                }
            }

            _digestComputations += 1
            // Review10 item 3: the streaming hash checks the stop flag between 64 KB
            // chunks, so a stop() never waits behind a full-file read stalled on a dead
            // share. An aborted digest is a stop, not an invalidity — return outright.
            let stopFlag = stopRequested
            guard let digest = FileIdentity.contentDigest(handle: handle, size: observed.size,
                                                          shouldAbort: { stopFlag.isSet })
            else {
                if stopRequested.isSet { return }                  // review10 item 3: aborted by stop()
                clearPendingEvidence(for: name)                    // review10 item 2
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: invalid
                continue
            }

            // Final revalidation on the pinned descriptor (review6 finding 1): the header/
            // completeness read and the digest read above take time, and an in-place writer
            // active DURING them moves size/mtime — the digest would then describe torn bytes.
            // Require the identity unchanged from the initial fstat; otherwise treat the file as
            // unstable this tick (record the latest clean observation, no emit, no dedup update,
            // no log spam) and let it re-earn stability on later ticks.
            guard let finalStat = Self.statFile(handle) else {
                clearPendingEvidence(for: name)                    // review10 item 2
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: invalid
                continue
            }
            guard finalStat == observed else {
                // Not an invalidity, an in-flight writer: record the LATEST clean stat so
                // stability re-earns from what the file is now (review10 item 2 keeps this
                // branch's existing shape — stat recorded, pending content cleared).
                lastSeenStat[name] = finalStat
                // Review8 finding 1: the identity moved mid-scan — restart the
                // digest-stability gate along with stat stability.
                pendingContent[name] = nil
                if revision != nil { holdRevisionsAbove = true }   // review10 item 1: unstable
                continue
            }

            guard lastEmittedDigest[name] != digest else {
                // Identical content re-published under a NEW identity (in-place
                // rewrite of the same bytes): record the new identity as the
                // emitted version so `.immutableAfterPublish` stops re-hashing it.
                lastEmittedIdentity[name] = observed
                // Review8 finding 1: an already-emitted digest supersedes any pending
                // observation — the file settled back onto known content, and the
                // pending digest was never observed long enough to count.
                pendingContent[name] = nil
                continue
            }

            // Digest-stability gate (review8 finding 1, `.mutableStackerOutput` only).
            // Stat stability cannot see an in-place rewriter that PAUSES mid-rewrite:
            // the size is unchanged and a coarse or restored mtime can collide, so the
            // digest just computed may describe a temporary A/B hybrid — and consumer-
            // side digest verification would then faithfully verify that exact hybrid,
            // because it proves byte identity, not producer completeness. Mirror the
            // two-tick stat philosophy at the content level: a NEW digest is emitted
            // only after the SAME digest is observed again, under the SAME stat
            // identity, at least `quietPeriod` of MONOTONIC time later. The elapsed-
            // time requirement matters because the event debounce and the poll timer
            // share this queue: two scans can land almost back-to-back, and two
            // near-simultaneous sightings prove nothing. A DIFFERENT digest replaces
            // the pending one (still unemitted); a stat-identity change or a folder-
            // generation change restarts the gate. THE ACCEPTED DESIGN BOUNDARY
            // (review9 item 5): passing this gate proves only that the content
            // remained unchanged for the quiet period — it does NOT prove the
            // producer's transaction ended. A writer that pauses on a hybrid through
            // BOTH observations therefore EMITS that hybrid: from this side of the
            // filesystem a long pause is indistinguishable from a finished write, and
            // no polling scheme can tell them apart. Only PRODUCER-SIDE atomic
            // publication (temp name + rename into place) is absolute. Pinned by
            // testMutablePolicy_pauseSpansBothObservations_hybridEmits_acceptedBoundary.
            // Cost: one extra poll tick of latency per live_stack update.
            // `.immutableAfterPublish` is unchanged — its files are immutable once
            // published by policy, and the identity gate above already governs them.
            if digestPolicy == .mutableStackerOutput {
                let now = monotonicNowNanos()
                if let pending = pendingContent[name], pending.digest == digest,
                   pending.identity == observed {
                    guard now >= pending.firstObservedNanos,
                          now - pending.firstObservedNanos >= quietPeriodNanos else {
                        if revision != nil { holdRevisionsAbove = true }   // review10 item 1: mid-gate
                        continue
                    }
                    // Gate satisfied. The pending observation is cleared at EMISSION below,
                    // not here — a held-back revision (review10 item 1) keeps its evidence
                    // and re-qualifies immediately once the lower revision clears.
                } else {
                    pendingContent[name] = PendingContent(digest: digest, identity: observed,
                                                          firstObservedNanos: now)
                    if revision != nil { holdRevisionsAbove = true }   // review10 item 1: mid-gate
                    continue
                }
            }

            // Review10 item 1 (HOLDBACK): every gate passed, but a LOWER-numbered revision
            // earlier in this scan is still earning its gates — emitting above it would
            // hand the consumer an order regression. This emission waits; its evidence is
            // intact, so it goes out on the first scan after the blocker clears.
            if revision != nil, holdRevisionsAbove { continue }

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
            // Review9 item 4: nothing may be emitted after stop() — a reentrant stop from an
            // onLog callback earlier in this scan lands here as a terminal-state no-op.
            // Review10 item 3: the atomic flag covers a stop() from ANOTHER thread whose
            // teardown is still queued behind this very scan (state not yet .stopped).
            guard state == .running, !stopRequested.isSet else { return }
            pendingContent[name] = nil          // the emission consumes the gate evidence
            lastEmittedDigest[name] = digest
            lastEmittedIdentity[name] = observed
            if let revision,
               emittedRevisionHighWater.map({ Self.numericCompare(revision, $0) == .orderedDescending })
                    ?? true {
                // Review10 item 1: advance the high-water mark at emission — the single
                // point a revision becomes consumer-visible.
                emittedRevisionHighWater = revision
            }
            continuation.yield(StackUpdate(
                url: url, fileSize: observed.size,
                identity: observed.withDigest(digest)))
        }
    }

    /// Review10 item 2: one observed per-file invalidity — open/fstat failure (incl. a
    /// rejected non-regular node), zero size, malformed or incomplete FITS header, digest
    /// failure — resets EVERYTHING pending for the entry. Stability and content evidence
    /// must be re-earned from zero: a file that vanished or truncated during the quiet
    /// window and returned with a manufactured matching identity (restored bytes +
    /// utimensat'd mtime, or a reused inode) must never emit off evidence gathered for a
    /// version that demonstrably stopped being valid. Emitted digests/identities are
    /// untouched — dedup is content-bound and survives invalidity; only UNEMITTED evidence
    /// dies.
    private func clearPendingEvidence(for name: String) {
        lastSeenStat.removeValue(forKey: name)
        pendingContent.removeValue(forKey: name)
    }

    /// Mid-tick folder replacement handling — shared by the top-of-scan identity check and the
    /// yield-time revalidation: log honestly, drop the stale source, clear PENDING stability
    /// observations AND the location-bound identity fast-path (emitted digests RETAINED for
    /// dedup — content-bound, they survive the generation change), and mark missing so the
    /// next tick re-arms via the recovery branch.
    private func handleFolderReplaced() {
        onLog?("watched folder was replaced — re-arming: \(folder.path)")
        cancelSource()
        lastSeenStat.removeAll()
        // Review8 finding 1: the digest-stability gate restarts with the folder generation.
        pendingContent.removeAll()
        // Review8 finding 2: identities die with the folder generation (see the
        // lastEmittedIdentity declaration for the digest/identity asymmetry).
        lastEmittedIdentity.removeAll()
        // Review10 item 1: the revision order gate is per-generation too (emitted digests
        // above still dedup any re-sighting of an already-emitted revision).
        emittedRevisionHighWater = nil
        outOfOrderDropLogged.removeAll()
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
