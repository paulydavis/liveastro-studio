import Foundation

/// Lifecycle misuse of a FolderFrameSource (cold1 M2, mirroring StackFileWatcherError):
/// the source is ONE-SHOT — initial → running → stopped (terminal). A failed initial
/// start stays retryable; a restart after stop() fails loudly instead of silently
/// yielding into a dead stream (which recorded an empty session).
public enum FolderFrameSourceError: Error, Equatable {
    /// start() while already running.
    case alreadyStarted
    /// start() after stop() — construct a new source instead.
    case stopped
    /// importOnce could not enumerate its source folder.
    case enumerationFailed(String)
}

/// Lock-guarded test seams for the live path (cold1 I2): a hook that fires when a LIGHT
/// update is buffered, and a counter of decode attempts — together they pin the lazy-decode
/// property (no RawFrame is constructed until the consumer pulls). Set the hook before
/// start(); both sides may touch these from different threads.
internal final class LiveDecodeSeams: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0
    private var bufferedHook: ((StackUpdate) -> Void)?
    var onUpdateBuffered: ((StackUpdate) -> Void)? {
        get { lock.withLock { bufferedHook } }
        set { lock.withLock { bufferedHook = newValue } }
    }
    func noteBuffered(_ u: StackUpdate) { onUpdateBuffered?(u) }
    func noteDecode() { lock.withLock { decodes += 1 } }
    var decodeCount: Int { lock.withLock { decodes } }
}

/// Lock-guarded log relay (review11 finding 5): lets a closure created in init log through
/// whatever sink is CURRENTLY assigned to `onLog` (assigned after init; may change; may be
/// read from the consumer's pull task while the owner reassigns it).
internal final class LogRelayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((String) -> Void)?
    var current: ((String) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }
    func emit(_ line: String) { current?(line) }
}

/// Reads raw frames from a folder, either as a one-shot import or by watching for new files.
///
/// BOTH modes are PULL-based (`AsyncStream(unfolding:)`): one file is decoded per consumer
/// pull, so peak memory stays O(1) frames regardless of folder size. Import mode pulls from
/// the sorted cursor. Live mode (cold1 I2) buffers only LIGHT items — the watcher's
/// StackUpdate (URL + FileIdentity) — and decodes at pull time: pre-fix the live task
/// decoded every emitted update eagerly into an unbounded RawFrame buffer, so a restart
/// onto a folder holding 1000+ subs decoded multi-GB of Float planes faster than the serial
/// consumer could stack them.
public final class FolderFrameSource: FrameSource {

    public enum Mode { case importOnce, live }

    public let frames: AsyncStream<RawFrame>
    public var isFinite: Bool { mode == .importOnce }
    public let totalCount: Int?
    /// Logging seam (mirrors FrameRelay.onLog). Forwarded to the inner StackFileWatcher
    /// when in live mode so folder-disappearance events surface in the app log, to the
    /// pull-time decoder so identity-mismatch and drop skips surface there too, and to the
    /// import pull closure (review11 finding 5) so import-mode drops are never silent.
    public var onLog: ((String) -> Void)? {
        didSet {
            livePull?.log = onLog
            importLog?.current = onLog
            liveWatcherLog?.current = onLog   // cold2 M2: reaches the inner watcher too
        }
    }
    /// Import mode only (review11 finding 5): lock-guarded relay behind the pull closure —
    /// the AsyncStream unfolding closure is created in init, BEFORE `onLog` can be assigned,
    /// so it logs through this box and the didSet above keeps it current.
    private let importLog: LogRelayBox?
    /// Live mode only (cold2 M2): lock-guarded relay the inner watcher logs through.
    /// Pre-fix `w.onLog` snapshotted `onLog` at start(), so a sink assigned AFTER
    /// start() — SessionPipeline wires it in startSources — never reached the watcher.
    /// The didSet above keeps this relay current instead.
    private let liveWatcherLog: LogRelayBox?
    /// Live mode only: continuation of the LIGHT update buffer (never RawFrames).
    private let liveUpdateContinuation: AsyncStream<StackUpdate>.Continuation?
    /// Live mode only: the pull-time decoder behind `frames`.
    private let livePull: LivePull?

    private let folder: URL
    private let mode: Mode
    private let fileNamePrefix: String?

    private let importCursor: ImportCursor?
    private var liveTask: Task<Void, Never>?
    private var watcher: StackFileWatcher?

    /// Test seams (cold1 I2): pin WHERE decode happens. `onUpdateBuffered` fires when a
    /// LIGHT update enters the live buffer; the decode counter counts decode attempts.
    internal let liveSeams: LiveDecodeSeams
    internal var liveDecodeCount: Int { liveSeams.decodeCount }

    /// Test seam (review11 finding 3): invoked in live mode AFTER the inner watcher has been
    /// constructed and started, BEFORE the lock is retaken to commit `.running` — the
    /// stop()-during-start() window, made deterministic. Receives the constructed watcher so
    /// tests can assert a loser is torn down, never leaked. nil in production. Install
    /// before start().
    internal var beforeStartCommit: ((StackFileWatcher) -> Void)?

    // MARK: Lifecycle (cold1 M2 — the watcher's one-shot contract, mirrored; review11 f3)
    //
    // stop() finishes the one-shot streams, so a second start() would relay into a dead
    // buffer and the session would record EMPTY with no error. The source is one-shot:
    // initial → starting (reserved under the lock) → running (committed) → stopped
    // (terminal). A FAILED initial start reverts to .initial — retryable. SessionPipeline
    // constructs a fresh source per session (AppModel.startSession / ImportController), so
    // this guard is pure safety that turns a silent empty session into a loud error through
    // the pipeline's start rollback.
    //
    // Review11 finding 3: `.starting` is RESERVED under the lock before any construction, so
    // two concurrent start() calls can never both build watchers (pre-fix the .initial check
    // and the .running assignment straddled unlocked watcher construction — the loser's
    // watcher leaked, armed forever, and both calls "succeeded"). The lock is RELEASED during
    // watcher construction/startup (it does I/O — never hold a lock over it), and the commit
    // REVALIDATES: if stop() won meanwhile (it marks .stopped from any state, including
    // .starting), the freshly built watcher is torn down and start() throws `.stopped` —
    // a stopped source is never resurrected onto an already-finished stream.
    private enum LifecycleState { case initial, starting, running, stopped }
    private let stateLock = NSLock()
    private var state: LifecycleState = .initial

    public init(folder: URL, mode: Mode, fileNamePrefix: String? = nil) {
        self.folder = folder
        self.mode = mode
        self.fileNamePrefix = fileNamePrefix
        let seams = LiveDecodeSeams()
        self.liveSeams = seams

        switch mode {
        case .importOnce:
            let cursor = ImportCursor(folder: folder, fileNamePrefix: fileNamePrefix)
            // Snapshot eagerly so totalCount is available before start() is called. If the
            // folder cannot be enumerated, init still succeeds (API compatibility) but the
            // cursor remembers the failure so start() can fail honestly instead of recording
            // a successful empty import.
            cursor.snapshotForInit()
            self.importCursor = cursor
            self.totalCount = cursor.fileCount
            self.liveUpdateContinuation = nil
            self.livePull = nil
            self.liveWatcherLog = nil
            let logBox = LogRelayBox()
            self.importLog = logBox
            // One file is read per pull; a file that cannot be loaded (deleted, unreadable,
            // corrupt, undecodable) is skipped WITH an honest log line naming the file and
            // the reason (review11 finding 5 — pre-fix `try?` dropped frames silently), and
            // the pull advances to the next file: one frame lost, never the session.
            self.frames = AsyncStream(unfolding: {
                while !Task.isCancelled {
                    do {
                        guard let url = try cursor.next() else { return nil }
                        do {
                            return try FolderFrameSource.loadRawFrame(url: url)
                        } catch {
                            logBox.emit("Skipped frame (\(url.lastPathComponent)): \(error)")
                        }
                    } catch let error as FolderFrameSourceError {
                        logBox.emit("Import enumeration failed (\(folder.path)): \(error)")
                        return nil
                    } catch {
                        logBox.emit("Import enumeration failed (\(folder.path)): \(error)")
                        return nil
                    }
                }
                return nil
            })

        case .live:
            self.importCursor = nil
            self.totalCount = nil
            self.importLog = nil
            self.liveWatcherLog = LogRelayBox()   // cold2 M2
            var cont: AsyncStream<StackUpdate>.Continuation!
            // AsyncStream's init runs this closure synchronously; cont is non-nil here.
            let updates = AsyncStream<StackUpdate> { cont = $0 }
            self.liveUpdateContinuation = cont
            let pull = LivePull(updates: updates, seams: seams)
            self.livePull = pull
            // Cold1 I2: the public frame stream decodes lazily — one pull, one decode.
            self.frames = AsyncStream(unfolding: { await pull.nextFrame() })
        }
    }

    /// Cold2 I2: a RUNNING live source dropped without stop() must not leak its live
    /// machinery — the armed folder fd, the poll timer, and the relay task are reachable
    /// only through this source, so without this fallback they ran forever (proven fd
    /// leak). Mirrors SessionPipeline's deinit: stop the inner watcher (bounded by its
    /// 5 s default) and cancel the relay task via the terminal stop(). deinit IS
    /// reachable while live: the relay task captures the watcher/continuation/seams,
    /// never self, and every callback seam is owned by the caller. stop() is terminal
    /// and idempotent, so an already-stopped source skips straight through.
    deinit {
        let running: Bool = stateLock.withLock { state == .running || state == .starting }
        guard running else { return }
        stop()
    }

    public func start() throws {
        // Cold1 M2 + review11 finding 3: reserve `.starting` under the lock BEFORE any
        // construction — concurrent start() calls are rejected here, so two racers can never
        // both build watchers. See the LifecycleState declaration.
        try stateLock.withLock {
            switch state {
            case .running, .starting: throw FolderFrameSourceError.alreadyStarted
            case .stopped: throw FolderFrameSourceError.stopped
            case .initial: state = .starting
            }
        }
        switch mode {
        case .importOnce:
            // Pull-based: just snapshot the sorted file list (I/O — outside the lock);
            // loading happens per pull.
            do {
                try importCursor?.snapshotIfNeeded()
            } catch {
                stateLock.withLock { if state == .starting { state = .initial } }
                throw error
            }
            // Commit (or bow to a stop() that won meanwhile; the cursor is already stopped).
            try commitRunning(onCommit: {}, tearDownOnStop: {})

        case .live:
            // Review7 P2: native relay / rig folders publish each sub ONCE and
            // never touch it again — an already-emitted identity is trusted, so
            // every poll costs one fstat per file instead of re-hashing the
            // whole (ever-growing) folder each scan.
            let w = StackFileWatcher(folder: folder, fileNamePrefix: fileNamePrefix,
                                     digestPolicy: .immutableAfterPublish)
            // Cold2 M2: log through the RELAY, never a snapshot of `onLog` — a sink
            // assigned after start() (SessionPipeline wires it in startSources) must
            // still reach the watcher. The relay is seeded with the current sink and
            // the onLog didSet keeps it live.
            let watcherLog = liveWatcherLog!
            watcherLog.current = onLog
            w.onLog = { watcherLog.emit($0) }
            do {
                try w.start()   // I/O — the lock is NOT held here
            } catch {
                // A failed initial start stays retryable: revert the reservation — unless
                // stop() already won the race, in which case terminal .stopped stands.
                stateLock.withLock { if state == .starting { state = .initial } }
                throw error
            }
            beforeStartCommit?(w)   // test seam: the stop-during-start window, deterministic
            let cont = liveUpdateContinuation!
            let seams = liveSeams
            // Revalidate + commit under the lock: watcher/liveTask become visible to stop()
            // atomically with `.running` (stop() reads them under the same lock).
            try commitRunning(onCommit: {
                self.watcher = w
                self.liveTask = Task.detached {
                    // Cold1 I2: relay LIGHT updates only — NO decode here. Decode happens on
                    // the consumer's clock in LivePull.nextFrame(), one frame in flight.
                    for await update in w.updates {
                        cont.yield(update)
                        seams.noteBuffered(update)
                    }
                    // The watcher stream ended (its stop()): close the buffer as a backstop
                    // so consumers never hang on a dead stream.
                    cont.finish()
                }
            }, tearDownOnStop: {
                // stop() won while the watcher was being built: tear the orphan down —
                // stopping it disarms its folder fd/timer and finishes its stream. The
                // source's own streams were already finished by stop(). No resurrection.
                // Cold2 M3: the RACING stop()'s budget governs this teardown too — a
                // caller with an overall shutdown budget (SessionPipeline.end()) must
                // not be pinned behind the watcher's 5 s default on top of it.
                w.stop(timeout: self.lastStopTimeout ?? 5.0)
            })
        }
    }

    /// Review11 finding 3: retake the lock and commit `.running`, or — when stop() won during
    /// the unlocked construction window — run `tearDownOnStop` and throw `.stopped` so the
    /// caller hears loudly that the source it started is already dead.
    private func commitRunning(onCommit: () -> Void, tearDownOnStop: () -> Void) throws {
        let stopWon: Bool = stateLock.withLock {
            guard state != .stopped else { return true }
            onCommit()          // runs under the lock — assignments are atomic with .running
            state = .running
            return false
        }
        if stopWon {
            tearDownOnStop()
            throw FolderFrameSourceError.stopped
        }
    }

    /// Protocol stop: bounded by the inner watcher's own 5 s default.
    public func stop() { stop(timeout: 5.0) }

    /// Bounded stop (cold1 M1): `timeout` caps the inner watcher's stop so a caller with
    /// an overall shutdown budget (SessionPipeline.end() charges this against its primary
    /// drain deadline) is never pinned behind the watcher default ON TOP of its own drain.
    /// Terminal (cold1 M2): a later start() throws. Light updates still buffered at stop
    /// time are discarded, not decoded — stop means stop. Review11 finding 3: `.stopped` is
    /// marked from ANY state — including `.starting`, so a start() in flight sees it at its
    /// commit revalidation and tears its watcher down instead of committing — and the
    /// watcher/task references are captured under the SAME lock that publishes them.
    public func stop(timeout: TimeInterval) {
        stopSeamLock.withLock { _lastStopTimeout = timeout }
        let (w, task): (StackFileWatcher?, Task<Void, Never>?) = stateLock.withLock {
            state = .stopped
            return (watcher, liveTask)
        }
        importCursor?.stop()
        livePull?.stop()
        w?.stop(timeout: timeout)
        task?.cancel()
        liveUpdateContinuation?.finish()
    }

    /// Cold1 I2: pull-time decoder for the live path. The buffered stream holds LIGHT
    /// StackUpdates; ONE frame is decoded per consumer pull, so peak memory stays O(1)
    /// frames no matter how many subs the watcher emits while the consumer lags.
    /// Single-consumer by contract (AsyncStream supports one meaningful iterator):
    /// `iterator` is touched only from the frames stream's unfolding closure, which
    /// AsyncStream serializes. The lock guards the cross-thread state (stop flag, log).
    private final class LivePull: @unchecked Sendable {
        private let lock = NSLock()
        private var iterator: AsyncStream<StackUpdate>.AsyncIterator
        private var stopped = false
        private var logSink: ((String) -> Void)?
        private let seams: LiveDecodeSeams

        init(updates: AsyncStream<StackUpdate>, seams: LiveDecodeSeams) {
            self.iterator = updates.makeAsyncIterator()
            self.seams = seams
        }

        var log: ((String) -> Void)? {
            get { lock.withLock { logSink } }
            set { lock.withLock { logSink = newValue } }
        }
        func stop() { lock.withLock { stopped = true } }
        private var isStopped: Bool { lock.withLock { stopped } }

        /// One consumer pull. The verified-read path (loadRawFrame(url:expectedIdentity:))
        /// is unchanged — it just runs NOW, at consumption. An identity mismatch or an
        /// unreadable file is skipped (the honest log lives inside frame(for:log:)) and
        /// the pull ADVANCES to the following update: a boundary failure may lose one
        /// frame, never the session — returning nil would end the live stream, so nil is
        /// reserved for stop()/cancellation/buffer end.
        func nextFrame() async -> RawFrame? {
            while !Task.isCancelled && !isStopped {
                guard let update = await iterator.next() else { return nil }
                seams.noteDecode()
                if let frame = FolderFrameSource.frame(for: update, log: log) {
                    return frame
                }
            }
            return nil
        }
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
        private var snapshotError: FolderFrameSourceError?
        private var index = 0
        private var stopped = false

        init(folder: URL, fileNamePrefix: String?) {
            self.folder = folder
            self.fileNamePrefix = fileNamePrefix
        }

        func snapshotForInit() {
            try? snapshotIfNeeded()
        }

        func snapshotIfNeeded() throws {
            try lock.withLock { try snapshotLocked() }
        }

        /// Number of files in the snapshot; 0 before snapshotIfNeeded() is called.
        var fileCount: Int {
            lock.withLock { files?.count ?? 0 }
        }

        func stop() {
            lock.withLock { stopped = true }
        }

        /// Next file to load, or nil at end of list / after stop().
        func next() throws -> URL? {
            try lock.withLock {
                guard !stopped else { return nil }
                try snapshotLocked()
                guard let files, index < files.count else { return nil }
                let url = files[index]
                index += 1
                return url
            }
        }

        private func snapshotLocked() throws {
            guard files == nil else { return }
            if let snapshotError { throw snapshotError }
            let fm = FileManager.default
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: folder.path)
            } catch {
                let failure = FolderFrameSourceError.enumerationFailed(
                    "\(folder.path): \(error.localizedDescription)"
                )
                snapshotError = failure
                throw failure
            }
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
    /// and this read) or an unreadable/undecodable file (deleted between emit and pull,
    /// permission failure, corruption, decode failure). EVERY skip is logged with the filename
    /// and the reason (review11 finding 5 — the generic path used to be silent): a boundary
    /// failure may lose one frame, never the session, and the loss must appear honestly in
    /// the log. Internal seam so the skip-vs-deliver decision is deterministically testable.
    static func frame(for update: StackUpdate, log: ((String) -> Void)?) -> RawFrame? {
        do {
            return try loadRawFrame(url: update.url, expectedIdentity: update.identity)
        } catch let mismatch as FileIdentityMismatchError {
            log?("file changed between validation and read — skipping \(mismatch.fileName)")
            return nil
        } catch {
            log?("Skipped frame (\(update.url.lastPathComponent)): \(error)")
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
