import XCTest
@testable import LiveAstroCore

final class StackFileWatcherTests: XCTestCase {
    var tmp: URL!
    var watcher: StackFileWatcher!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        watcher?.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFITS(_ value: Float, size: Int = 8) -> Data {
        FITSWriter.float32(width: size, height: size, channels: 1,
                           pixels: [Float](repeating: value, count: size * size))
    }

    /// Collects updates into an actor-guarded array.
    private func collect(_ watcher: StackFileWatcher) -> Collector {
        let c = Collector()
        Task { for await u in watcher.updates { await c.add(u) } }
        return c
    }

    actor Collector {
        private(set) var items: [StackUpdate] = []
        func add(_ u: StackUpdate) { items.append(u) }
        func waitForCount(_ n: Int, timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if items.count >= n { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return items.count >= n
        }
    }

    func testStartThrowsForNonexistentFolder() {
        let w = StackFileWatcher(folder: URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        XCTAssertThrowsError(try w.start())
    }

    func testEmitsOnCompleteFITSWrite() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.5)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "expected one update for a complete FITS write")
    }

    func testIgnoresPartialFITSUntilComplete() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try full.prefix(full.count / 2).write(to: url)      // partial: header claims more data
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let premature = await collector.waitForCount(1, timeout: 0.1)
        XCTAssertFalse(premature, "must not emit for a partial FITS file")
        try full.write(to: url)                              // complete rewrite
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
    }

    func testIgnoresPreallocatedFITSUntilStable() async throws {
        // A writer that preallocates the FULL declared size, then fills pixels in place,
        // passes the size>=declared check on the first sighting. It must NOT emit until the
        // file is stable (size AND mtime unchanged across two ticks).
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url = tmp.appendingPathComponent("live_stack.fit")
        // Preallocate full size with zeroed pixel region (header valid, size == declared),
        // then keep bumping mtime as if pixels are being written in place.
        let header = full.prefix(full.count).count   // full declared length
        _ = header
        try full.write(to: url)                       // full size on disk immediately
        // Simulate in-place pixel writes: rewrite the file (bumps mtime) a few times.
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let fh = try FileHandle(forWritingTo: url)
            try fh.seek(toOffset: 0)
            fh.write(full)                            // same size, new mtime → not stable
            try fh.close()
        }
        // During the active-write window it must not have emitted.
        let premature = await collector.waitForCount(1, timeout: 0.1)
        XCTAssertFalse(premature, "must not emit a preallocated FITS while it is still being written")
        // Now stop touching it → it stabilizes → emits once.
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "a stabilized FITS must emit")
    }

    func testDeduplicatesIdenticalContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        let data = makeFITS(0.5)
        try data.write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try data.write(to: url)                              // same bytes again
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1, "identical content must not re-emit")
    }

    func testEmitsAgainOnChangedContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.3).write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try makeFITS(0.6).write(to: url)
        let got = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(got, "changed content must emit a second update")
    }

    func testFileNamePrefixFilter() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3, fileNamePrefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.4).write(to: tmp.appendingPathComponent("Light_NGC6888_001.fit"))  // raw sub — must be ignored
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))          // stack — must emit
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].url.lastPathComponent, "live_stack.fit")
    }

    func testIgnoresTempAndHiddenFiles() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent(".hidden.fit"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("scratch.tmp"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - review7 P2: identity-gated hashing (digest policy)

    /// Restore a file's mtime with utimensat(2) at NANOSECOND precision (atime untouched).
    /// This is how the collision tests manufacture an identity (dev, ino, size, mtime-ns)
    /// EXACTLY equal to a previously observed version, deterministically on any filesystem.
    private func setMtime(_ url: URL, sec: Int64, nsec: Int64,
                          file: StaticString = #filePath, line: UInt = #line) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: time_t(sec), tv_nsec: Int(nsec))]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0,
                       "utimensat must succeed", file: file, line: line)
    }

    /// Mutate ONE interior byte of `url` in place (same size), then restore the file's
    /// mtime to `identity`'s ns-exact value — a manufactured identity collision. `byte`
    /// selects the content version (review8: tests distinguish a mid-rewrite hybrid from
    /// the finished rewrite by writing different bytes at the same offset).
    private func mutateInteriorPreservingIdentity(_ url: URL, byteFromEnd: Int,
                                                  identity: FileIdentity,
                                                  byte: UInt8 = 0xAB) throws {
        let fh = try FileHandle(forWritingTo: url)
        let size = try fh.seekToEnd()
        try fh.seek(toOffset: size - UInt64(byteFromEnd))
        fh.write(Data([byte]))
        try fh.close()
        setMtime(url, sec: identity.mtimeSec, nsec: identity.mtimeNsec)
        XCTAssertEqual(FileIdentity.capture(url: url), identity,
                       "the manufactured identity collision must actually collide")
    }

    /// Review7 P2 (the O(1) win, red-first): under `.immutableAfterPublish` an emitted
    /// file whose identity never changes must not be re-hashed on ANY later scan — one
    /// fstat per poll. Pre-fix the digest counter grew on every scan.
    func testImmutablePolicy_noRehashWhileIdentityUnchanged() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.2,
                                   digestPolicy: .immutableAfterPublish)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("sub_001.fit"))
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        let after = watcher.digestComputations
        XCTAssertGreaterThan(after, 0, "the emission itself must have hashed")
        try await Task.sleep(nanoseconds: 1_500_000_000)   // ≥5 further polls
        XCTAssertEqual(watcher.digestComputations, after,
                       "an emitted, identity-unchanged file must never be re-hashed")
        let items = await collector.items
        XCTAssertEqual(items.count, 1)
    }

    /// Review7 P2 counterpart: the default `.mutableStackerOutput` (Siril path) keeps
    /// re-hashing every stable scan BY DESIGN — identity is not trusted for in-place
    /// rewriters — while digest-keyed dedup still suppresses re-emission.
    func testMutablePolicy_rehashesEveryStableScanByDesign() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.2)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        let after = watcher.digestComputations
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertGreaterThan(watcher.digestComputations, after,
                             "the mutable policy must keep re-hashing stable scans")
        let items = await collector.items
        XCTAssertEqual(items.count, 1, "identical content must still dedup on the digest")
    }

    /// Reviewer-specified regression (review7 P2): interior bytes change IN PLACE and the
    /// ORIGINAL mtime is restored ns-exact with utimensat(2) — an identity collision
    /// (dev, ino, size, mtime-ns all equal the emitted version) manufactured
    /// deterministically. utimensat stands in for the REAL-WORLD case identity-gating
    /// cannot see: coarse or cached filesystem timestamps letting an in-place rewrite land
    /// on the identical mtime. The MUTABLE policy must still re-hash the stable file and
    /// EMIT the changed digest — the content update is never lost. Review8 finding 1 adds
    /// the digest-stability gate on top: the changed digest must be observed on TWO
    /// separated scans before it emits, so the emission lands one poll tick later — the
    /// intent (the stat-identical content change IS eventually emitted) is unchanged.
    func testMutablePolicy_identityCollisionStillEmitsChangedContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.2,
                                   digestPolicy: .mutableStackerOutput)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)

        let emitted = FileIdentity.capture(url: url)!
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted)

        let reEmitted = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(reEmitted, "the mutable policy must re-hash and emit the changed content")
        let items = await collector.items
        XCTAssertNotEqual(items[0].identity?.digest, items[1].identity?.digest,
                          "the two emissions must carry different content digests")
    }

    /// The immutable policy legitimately SKIPS the same manufactured collision: identity
    /// unchanged = presumed immutable is the documented policy trade (native relay subs
    /// are written once and never touched) — the flat digest counter above is the win
    /// this trade buys.
    func testImmutablePolicy_identityCollisionSkippedByDesign() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.2,
                                   digestPolicy: .immutableAfterPublish)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("sub_001.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        let hashesAfterEmit = watcher.digestComputations

        let emitted = FileIdentity.capture(url: url)!
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1,
                       "identity collision is skipped by design under the immutable policy")
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit,
                       "no re-hash either — that is the entire point of the policy")
    }

    // MARK: - review9 item 3: FIFO wedge

    /// Review9 item 3 (red-first: pre-fix this test WEDGED the suite): candidates were
    /// opened with a BLOCKING O_RDONLY openat without verifying the file type, so
    /// `mkfifo blocked.fit` with no writer parked the ONLY watcher queue inside openat
    /// forever — no later file, no recovery, and stop() (once queue-confined) could
    /// never run. The open must be non-blocking, fstat must reject anything but
    /// S_IFREG (skipped silently like any per-file failure), and the neighboring valid
    /// FITS must emit normally. The FIFO name sorts BEFORE the FITS so it is opened
    /// first — proving a wedge would have blocked the later candidate.
    func testFIFONamedLikeImage_skippedSilently_neighborEmits_watcherNeverWedges() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        let fifo = tmp.appendingPathComponent("aaa_blocked.fit")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "arrange: mkfifo must succeed")
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        try watcher.start()
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "the valid FITS next to the writer-less FIFO must emit normally")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["live_stack.fit"],
                       "the FIFO itself must never be emitted")
        watcher.stop()   // must return — a wedged queue would hang here (or in tearDown)
    }

    // MARK: - review9 item 4: lifecycle (queue confinement, one-shot state, no resurrection)

    /// Lock-protected log capture: onLog fires on the watcher queue while the test
    /// thread asserts.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// Review9 item 4 (red-first): a scan parked across stop() — here replayed through the
    /// manual-scan seam — must observe the terminal state and neither RE-ARM (resurrection:
    /// pre-fix the recovery branch reopened the folder fd, logged "resuming", and left a live
    /// DispatchSource on a stopped watcher) nor emit anything later.
    func testStopDuringParkedRecoveryScan_noRearmNoLaterEmission() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        // The folder disappears; the watcher notices and enters the missing state.
        let aside = tmp.deletingLastPathComponent()
            .appendingPathComponent("watch-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: tmp, to: aside)
        watcher.scanNow()
        XCTAssertTrue(logs.all.contains { $0.contains("disappeared") }, "arrange: missing noticed")
        // The folder returns WITH a fresh valid file — the recovery scan is now "parked":
        // stop() lands before it runs.
        try FileManager.default.moveItem(at: aside, to: tmp)
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        watcher.stop()
        // The parked recovery scan resumes after stop(): it must no-op.
        watcher.scanNow()
        watcher.scanNow()
        clock.advance(seconds: 3601)
        watcher.scanNow()
        XCTAssertFalse(logs.all.contains { $0.contains("resuming") },
                       "a scan resumed after stop() must not re-arm (no resurrection)")
        try await Task.sleep(nanoseconds: 200_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty, "no emission may follow stop()")
    }

    /// Review9 item 4: lifecycle state is queue-confined, so stop() synchronizes onto the
    /// watcher queue — and an onLog callback (which RUNS on that queue) invoking stop()
    /// must be detected as reentrant and run inline, not deadlock through queue.sync.
    func testOnLogInvokingStop_noDeadlock_cleanStop() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let w = watcher!
        watcher.onLog = { [weak w] msg in
            if msg.contains("disappeared") { w?.stop() }   // reentrant stop from the queue
        }
        let collector = collect(watcher)
        try watcher.start()
        let aside = tmp.deletingLastPathComponent()
            .appendingPathComponent("watch-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: tmp, to: aside)
        watcher.scanNow()   // fires onLog("disappeared") on the queue → inline stop(); a
                            // deadlock would hang this line forever
        try FileManager.default.moveItem(at: aside, to: tmp)   // restore for teardown
        watcher.stop()      // idempotent second stop — must be a clean no-op
        watcher.scanNow()   // and post-stop scans must no-op
        try await Task.sleep(nanoseconds: 200_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty, "clean stop — nothing emitted")
    }

    /// Review9 item 4: repeated start() while running previously overwrote the live
    /// source/timer references (leaking the armed fd and a running timer). It must fail
    /// explicitly instead.
    func testRepeatedStartWhileRunning_failsExplicitly() throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600)
        try watcher.start()
        XCTAssertThrowsError(try watcher.start()) {
            XCTAssertEqual($0 as? StackFileWatcherError, .alreadyStarted)
        }
    }

    /// Review9 item 4: the state machine is ONE-SHOT — initial → running → stopped, with
    /// stopped terminal. start() after stop() must fail explicitly, never resurrect.
    func testStartAfterStop_failsTerminally() throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600)
        try watcher.start()
        watcher.stop()
        XCTAssertThrowsError(try watcher.start()) {
            XCTAssertEqual($0 as? StackFileWatcherError, .stopped)
        }
    }

    /// Review9 item 4: a FAILED initial start (folder absent) leaves the watcher in the
    /// initial state — RETRYABLE, not terminal. A second start() once the folder exists
    /// succeeds.
    func testFailedFirstStart_leavesWatcherRetryable() throws {
        let folder = tmp.appendingPathComponent("appears-later", isDirectory: true)
        watcher = StackFileWatcher(folder: folder, quietPeriod: 3600, pollInterval: 3600)
        XCTAssertThrowsError(try watcher.start(), "arrange: first start fails (no folder)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNoThrow(try watcher.start(), "a failed initial start must be retryable")
    }

    // MARK: - review8 finding 1: digest-stability gate (mutable policy)

    /// Lock-protected manual monotonic clock injected through the watcher's
    /// `monotonicNowNanos` seam: tests advance it explicitly, so the gate's quiet-period
    /// separation requirement is exercised with ZERO wall-clock sleeps — the debounce and
    /// poll timer are parked on huge intervals and scans are driven one at a time through
    /// scanNow(). (The watcher reads the clock on its serial queue while the test thread
    /// advances it — lock-protect, F5 pattern.)
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64 = 1_000_000_000
        func now() -> UInt64 { lock.withLock { nanos } }
        func advance(seconds: TimeInterval) {
            lock.withLock { nanos += UInt64(seconds * 1_000_000_000) }
        }
    }

    /// A manually-driven watcher: debounce and poll parked on huge intervals (nothing runs
    /// except explicit scanNow() calls) with an injected manual monotonic clock. The huge
    /// quietPeriod is ALSO the digest-stability separation requirement, so tests must
    /// advance the clock past it to confirm a pending digest.
    private func makeManualWatcher(policy: StackFileWatcher.DigestPolicy,
                                   clock: ManualClock,
                                   prefix: String? = nil) throws -> StackFileWatcher {
        let w = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600,
                                 fileNamePrefix: prefix, digestPolicy: policy)
        w.monotonicNowNanos = { clock.now() }
        return w
    }

    // MARK: - review9 item 1: hybrid per-entry policy (numbered stacker revisions)

    /// Review9 item 1 (red-first, the counter arithmetic proves both halves): under
    /// `.mutableStackerOutput` every matching file was re-hashed on EVERY stable scan —
    /// with Siril 1.4+'s numbered revisions (live_stack_00001.fit …) accumulating, 1000
    /// × 50 MB revisions meant 50 GB hashed per 2 s scan, starving new updates. Numbered
    /// revisions are written once and never rewritten, so after their CONFIRMED first
    /// emission they must use the identity fast-path (digest computations FLAT), while
    /// the CLASSIC in-place fixed-name file keeps re-hashing each stable scan by design:
    /// with one classic + three numbered files emitted, k further scans must add
    /// EXACTLY k digest computations (classic only), not 4k.
    func testMutablePolicy_numberedRevisionsFlatAfterEmission_classicStillRehashes() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        for i in 1...3 {
            try makeFITS(Float(i) * 0.1)
                .write(to: tmp.appendingPathComponent("live_stack_0000\(i).fit"))
        }
        watcher.scanNow()                     // sighting — stat recorded, nothing hashed
        watcher.scanNow()                     // stable → 4 digests → all 4 pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // 4 digests confirm the pendings → 4 emissions
        let got = await collector.waitForCount(4, timeout: 2)
        XCTAssertTrue(got, "arrange: classic + 3 numbered revisions all emit")
        let hashesAfterEmit = watcher.digestComputations
        XCTAssertEqual(hashesAfterEmit, 8,
                       "arrange: 4 pending digests + 4 confirming digests, nothing else")

        for _ in 0..<3 { clock.advance(seconds: 3601); watcher.scanNow() }
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit + 3,
                       "exactly ONE hash per further scan: the classic in-place file still " +
                       "re-hashes, all emitted numbered revisions stay FLAT")
        let items = await collector.items
        XCTAssertEqual(items.count, 4, "no re-emissions during the flat scans")
    }

    /// Review9 item 1, the pre-emission half: a numbered revision may be written
    /// NON-ATOMICALLY before publication, so it must NOT ride the raw
    /// `.immutableAfterPublish` branch (which has no content gate). Its FIRST emission
    /// earns stat stability AND the two-observation digest-stability gate exactly like
    /// the classic file — a single stable sighting of a new numbered file must not emit.
    /// Post-emission trust is the ONLY divergence point.
    func testMutablePolicy_newNumberedRevision_firstEmissionStillPassesDigestGate() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.7).write(to: tmp.appendingPathComponent("live_stack_00004.fit"))
        watcher.scanNow()                     // first sighting — stat recorded only
        watcher.scanNow()                     // stable → digest PENDING, must not emit
        let single = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(single,
                       "a single stable sighting of a new numbered revision must not emit " +
                       "(the digest gate applies to its first emission)")
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // same digest after the quiet period → emits
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "the confirmed first emission goes through")
        // …and only THEN does the identity fast-path take over.
        let hashesAfterEmit = watcher.digestComputations
        clock.advance(seconds: 3601)
        watcher.scanNow()
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit,
                       "post-confirmation the numbered revision is never re-hashed")
    }

    // MARK: - review9 item 2: deterministic emission ordering

    /// Review9 item 2 (red-first): enumerateDirectory returns raw readdir order (POSIX-
    /// undefined), so several revisions accumulating during a reconnect could emit
    /// _00010 → _00002 → _00009, visually regressing the replay. Candidates must be
    /// sorted with the SAME parser that classifies them: numbered revisions in NUMERIC
    /// order via digit-STRING comparison (length, then lexicographic) — the 30-digit
    /// suffix must classify and sort identically, never overflow an Int conversion into
    /// a different path. Files are created in deliberately scrambled order.
    func testNumberedRevisions_scrambledCreationOrder_emitInNumericOrder() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        let thirtyDigits = String(repeating: "0", count: 28) + "11"   // numerically 11
        let creationOrder = ["live_stack_00010.fit", "live_stack_\(thirtyDigits).fit",
                             "live_stack_00002.fit", "live_stack_00009.fit"]
        for (i, name) in creationOrder.enumerated() {
            try makeFITS(Float(i + 1) * 0.1).write(to: tmp.appendingPathComponent(name))
        }
        watcher.scanNow()                     // sighting
        watcher.scanNow()                     // stable → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // confirmed → all emit, in candidate order
        let got = await collector.waitForCount(4, timeout: 2)
        XCTAssertTrue(got, "arrange: all four revisions emit")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00002.fit", "live_stack_00009.fit",
                        "live_stack_00010.fit", "live_stack_\(thirtyDigits).fit"],
                       "emissions must arrive in NUMERIC revision order regardless of " +
                       "creation/readdir order (30-digit suffix sorts numerically too)")
    }

    // MARK: - review10 item 1: cross-scan revision ordering (high-water mark + holdback)

    /// Review10 item 1a (red-first): the review9 sort fixed INTRA-scan order only. An
    /// incomplete _00001 (still mid digest-gate) was skipped while a complete _00002
    /// emitted; _00001 then emitted on a later scan → the consumer saw [2, 1] and the
    /// replay regressed. HOLDBACK: once a numbered revision is not yet emittable this
    /// scan, no HIGHER-numbered revision may emit this scan — it waits (its own gate
    /// evidence intact) until the lower revision clears. Both then emit in order [1, 2].
    func testNumberedRevisions_lowerRevisionMidGate_higherHeldBack_emitInOrder() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        // _00002 gets a one-scan head start on its gates, so it is confirmable while
        // _00001 is still one gate-tick behind.
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        watcher.scanNow()                     // _00002 sighted
        try makeFITS(0.1).write(to: tmp.appendingPathComponent("live_stack_00001.fit"))
        watcher.scanNow()                     // _00001 sighted; _00002 stable → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // _00001 pending; _00002 gate SATISFIED — pre-fix
                                              // it emitted here, ahead of _00001
        let premature = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(premature,
                       "_00002 must be held back while _00001 is still earning its gates")
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // _00001 confirms → emits; _00002 follows in order
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "both revisions emit once the lower one clears its gates")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00001.fit", "live_stack_00002.fit"],
                       "the consumer must see revisions in numeric order, never [2, 1]")
    }

    /// Review10 item 1b (red-first): a numbered revision arriving AFTER a higher one has
    /// already emitted is permanently dropped — emitting it would regress the consumer's
    /// replay. The frame is lost, the session preserved, and the drop appears honestly in
    /// the log exactly ONCE (not per tick).
    func testNumberedRevisions_lowerRevisionAfterHigherEmitted_droppedWithHonestLog() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        watcher.scanNow()                     // sighted
        watcher.scanNow()                     // stable → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // confirmed → _00002 emits (high-water 00002)
        let gotHigh = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(gotHigh, "arrange: _00002 emits first")

        // _00001 arrives late — below the high-water mark.
        try makeFITS(0.1).write(to: tmp.appendingPathComponent("live_stack_00001.fit"))
        for _ in 0..<4 { clock.advance(seconds: 3601); watcher.scanNow() }
        let late = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(late, "a revision below the high-water mark must never emit")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["live_stack_00002.fit"])
        let dropLines = logs.all.filter {
            $0 == "revision 00001 arrived out of order — skipped (high-water 00002)"
        }
        XCTAssertEqual(dropLines.count, 1,
                       "the drop must be logged honestly, exactly once — got \(logs.all)")
    }

    // MARK: - review10 item 2: observed invalidity resets pending evidence

    /// Review10 item 2 (red-first): the per-file invalidity branches (open failure, zero
    /// size, malformed header, digest failure) left lastSeenStat and pendingContent
    /// INTACT, so a file that truncated to zero DURING the quiet window and came back
    /// with a manufactured matching identity emitted IMMEDIATELY off the stale evidence.
    /// Invalidity must reset both gates: the returned file re-earns two-tick stat
    /// stability AND the digest gate before emitting.
    func testMutablePolicy_truncationDuringGate_evidenceResets_reEarnsBothGates() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        let original = makeFITS(0.25, size: 16)
        try original.write(to: url)
        watcher.scanNow()   // stability tick 1 — stat recorded
        watcher.scanNow()   // stable → digest observed → PENDING
        let identity = try XCTUnwrap(FileIdentity.capture(url: url))

        // The file truncates to ZERO mid-gate — an observed invalidity.
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: 0)
        try fh.close()
        watcher.scanNow()   // invalidity observed → ALL pending evidence must reset

        // The original bytes return under a MANUFACTURED matching identity (in-place
        // rewrite restores the size, utimensat restores mtime-ns: dev/ino/size/mtime all
        // equal the evidence gathered above).
        let wfh = try FileHandle(forWritingTo: url)
        try wfh.write(contentsOf: original)
        try wfh.close()
        setMtime(url, sec: identity.mtimeSec, nsec: identity.mtimeNsec)
        XCTAssertEqual(FileIdentity.capture(url: url), identity,
                       "arrange: the manufactured identity matches the pre-truncation one")

        clock.advance(seconds: 3601)   // a wrongly-retained pending would now be 'elapsed'
        watcher.scanNow()              // pre-fix: stale stability + stale pending → emitted here
        let premature = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(premature,
                       "no emission off stale pre-invalidity evidence — both gates re-earn from zero")

        watcher.scanNow()              // re-earned stability → fresh pending
        clock.advance(seconds: 3601)
        watcher.scanNow()              // fresh pending confirmed → emits
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "the restored file emits after re-earning stability + digest gates")
        let items = await collector.items
        XCTAssertEqual(items.count, 1)
    }

    /// Review10 item 2, absent-during-window variant (red-first): a file that VANISHES
    /// mid-gate keeps no pending evidence either. Modeled deterministically by moving the
    /// file aside (rename preserves inode and mtime) across one scan and back — the
    /// returned file presents the EXACT pre-absence identity, and pre-fix the stale
    /// stability + pending digest emitted it immediately.
    func testMutablePolicy_fileAbsentMidGate_pendingEvidenceCleared_reEarns() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        watcher.scanNow()   // stability tick 1
        watcher.scanNow()   // stable → pending digest observation

        // The file disappears for one scan (move-aside: same inode, same mtime)…
        let aside = tmp.appendingPathComponent("aside.bin")
        try FileManager.default.moveItem(at: url, to: aside)
        watcher.scanNow()   // absence observed while pending (unemitted) evidence exists
        // …and returns bit- and identity-identical.
        try FileManager.default.moveItem(at: aside, to: url)

        clock.advance(seconds: 3601)
        watcher.scanNow()   // pre-fix: stale evidence emitted here
        let premature = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(premature, "an absent-then-returned file must re-earn both gates")

        watcher.scanNow()   // stable again → fresh pending
        clock.advance(seconds: 3601)
        watcher.scanNow()   // confirmed → emits
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "the returned file emits after re-earning both gates")
        let items = await collector.items
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - review10 item 6: numeric sort with mixed zero padding

    /// Review10 item 6 (red-first): digitStringLess compared RAW digit-string lengths, so
    /// "10" sorted before "002" — mixed zero padding scrambled the numeric order the
    /// review9 sort was built to guarantee. Leading zeros must be numerically
    /// insignificant: _002, _0009, _10 emit as 2, 9, 10.
    func testNumberedRevisions_mixedZeroPadding_emitInNumericOrder() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        for (i, name) in ["live_stack_10.fit", "live_stack_002.fit",
                          "live_stack_0009.fit"].enumerated() {
            try makeFITS(Float(i + 1) * 0.1).write(to: tmp.appendingPathComponent(name))
        }
        watcher.scanNow()                     // sighting
        watcher.scanNow()                     // stable → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // confirmed → emit in numeric order
        let got = await collector.waitForCount(3, timeout: 2)
        XCTAssertTrue(got, "arrange: all three revisions emit")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_002.fit", "live_stack_0009.fit", "live_stack_10.fit"],
                       "leading zeros are numerically insignificant: 2 < 9 < 10")
    }

    /// Review10 item 6, equal-value tiebreak: _007 and _7 are the SAME revision number.
    /// The raw-string tiebreak makes the order deterministic (_007 first), and the
    /// high-water mark then drops the duplicate revision number honestly — the consumer
    /// never sees revision 7 twice.
    func testNumberedRevisions_equalValueDifferentPadding_deterministicTiebreak() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_007.fit"))
        try makeFITS(0.6).write(to: tmp.appendingPathComponent("live_stack_7.fit"))
        watcher.scanNow()                     // sighting
        watcher.scanNow()                     // stable → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                     // _007 (raw tiebreak first) emits; _7 = duplicate
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got)
        clock.advance(seconds: 3601)
        watcher.scanNow()
        let dup = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(dup, "the duplicate revision number must not emit a second time")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["live_stack_007.fit"],
                       "equal numeric values tie-break on the raw string — deterministic")
        XCTAssertTrue(logs.all.contains(
            "revision 7 arrived out of order — skipped (high-water 007)"),
            "the duplicate drop appears honestly in the log — got \(logs.all)")
    }

    /// Review8 finding 1 (red-first): stat stability is satisfied while an in-place
    /// rewriter PAUSES mid-rewrite (size unchanged, mtime coarse/restored), so pre-fix the
    /// watcher hashed the temporary A/B hybrid and emitted it immediately — and the
    /// consumer then correctly verified that exact hybrid, because digest verification
    /// proves byte identity, not producer completeness. The digest-stability gate must
    /// hold a NEW digest as pending and emit only when the SAME digest is observed again
    /// at least `quietPeriod` of MONOTONIC time later; a DIFFERENT digest on a later scan
    /// replaces the pending one, still unemitted.
    ///
    /// Review9 item 5 (honest scope): this proves the SHORT-pause case only — the pause
    /// here does NOT span both gate observations (the rewrite finishes before the pending
    /// hybrid could be confirmed). A writer that pauses on the hybrid through BOTH
    /// observations DOES emit it — see
    /// testMutablePolicy_pauseSpansBothObservations_hybridEmits_acceptedBoundary.
    func testMutablePolicy_midRewritePause_shorterThanQuietPeriod_hybridNotEmitted() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        watcher.scanNow()                       // sighting — records stat
        watcher.scanNow()                       // stable → digest A becomes pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // A confirmed after the quiet period → emits
        let gotA = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(gotA, "version A emits")

        let emitted = FileIdentity.capture(url: url)!
        // Mid-rewrite pause: interior bytes hold the A/B hybrid H; the identity
        // (size, mtime-ns) collides with the emitted version, so stat stability is
        // already satisfied — pre-fix, this scan emitted H.
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted, byte: 0xAB)
        let hybridDigest = FileIdentity.contentDigest(data: try Data(contentsOf: url))
        watcher.scanNow()                       // H observed ONCE → pending, must NOT emit
        let hybridEmitted = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(hybridEmitted,
                       "a single sighting of a new digest must not emit (mid-rewrite pause)")

        // The rewrite finishes: final version B, identity restored again (worst case).
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted, byte: 0xCD)
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // B ≠ pending H → pending replaced, no emit
        let replacedEmitted = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(replacedEmitted,
                       "a digest different from the pending one replaces it — H is never emitted")
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // B confirmed after the quiet period → emits
        let gotB = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(gotB, "the finished rewrite emits")
        let items = await collector.items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].identity?.digest,
                       FileIdentity.contentDigest(data: try Data(contentsOf: url)),
                       "the second emission is the FINISHED rewrite")
        XCTAssertFalse(items.contains { $0.identity?.digest == hybridDigest },
                       "the unfinished hybrid's digest must never be emitted")
    }

    /// Review9 item 5 — the ACCEPTED DESIGN BOUNDARY, documented as behavior: a writer
    /// that pauses on hybrid H through BOTH digest-gate observations EMITS H. The gate
    /// proves only that the content remained unchanged for the quiet period; it cannot
    /// prove the producer's transaction ended — from the watcher's side, a long pause on
    /// a hybrid is indistinguishable from a finished write, and no amount of polling can
    /// tell them apart. Only PRODUCER-SIDE atomic publication (write to a temp name, then
    /// rename into place) is absolute. This test pins the limit honestly so a future
    /// change that silently widens or narrows it fails loudly.
    func testMutablePolicy_pauseSpansBothObservations_hybridEmits_acceptedBoundary() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        watcher.scanNow()                       // sighting
        watcher.scanNow()                       // stable → digest A pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // A confirmed → emits
        let gotA = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(gotA, "arrange: version A emits")

        // The writer pauses on hybrid H — and stays paused across BOTH observations.
        let emitted = FileIdentity.capture(url: url)!
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted, byte: 0xAB)
        let hybridDigest = FileIdentity.contentDigest(data: try Data(contentsOf: url))
        watcher.scanNow()                       // H observed once → pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // H observed AGAIN, quiet period elapsed → emits
        let gotH = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(gotH, "the long-paused hybrid IS emitted — the accepted boundary")
        let items = await collector.items
        XCTAssertEqual(items.last?.identity?.digest, hybridDigest,
                       "and the emitted digest is the hybrid's — this is the documented limit")
    }

    /// Review8 finding 1, confirmation path: a stat-identical rewrite (utimensat identity
    /// collision) is emitted only on a SECOND sighting of the same digest separated by at
    /// least `quietPeriod` of MONOTONIC time — near-back-to-back scans (the event debounce
    /// and the poll timer share the serial queue) must NOT count as separated
    /// observations. Exactly one emission for B; the content change is never lost.
    func testMutablePolicy_sameDigestTwice_requiresQuietPeriodSeparation() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.25, size: 16).write(to: url)
        watcher.scanNow()                       // sighting
        watcher.scanNow()                       // stable → digest A pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // A confirmed → emits
        let gotA = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(gotA, "version A emits")

        let emitted = FileIdentity.capture(url: url)!
        try mutateInteriorPreservingIdentity(url, byteFromEnd: 64, identity: emitted)
        watcher.scanNow()                       // B observed once → pending
        let firstSighting = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(firstSighting, "the first sighting of B must not emit")
        watcher.scanNow()                       // same digest, ~zero monotonic separation
        let backToBack = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(backToBack,
                       "back-to-back scans are not separated observations — no emit before the quiet period")
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // same digest, separation satisfied → emits
        let gotB = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(gotB,
                      "B emits once its digest is observed unchanged across the quiet period")
        clock.advance(seconds: 3601)
        watcher.scanNow()                       // already-emitted digest → dedup
        let reEmitted = await collector.waitForCount(3, timeout: 0.3)
        XCTAssertFalse(reEmitted, "B emits exactly once")
    }

    // MARK: - review8 finding 2: the identity fast-path dies with the folder generation

    /// Emit one immutable-policy sub through manual scans and prove the identity fast-path
    /// is active (digest counter flat on a further scan). Returns the collector and the
    /// digest count after the emission. Shared arrange step for the finding-2 pair.
    private func emitBaselineSubWithFastPathActive(_ url: URL) async throws
        -> (collector: Collector, hashesAfterEmit: Int) {
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.25, size: 16).write(to: url)
        watcher.scanNow()   // sighting — records stat
        watcher.scanNow()   // stable → hash → emit (immutable policy: no digest gate)
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "arrange: baseline sub emits")
        let hashesAfterEmit = watcher.digestComputations
        XCTAssertGreaterThan(hashesAfterEmit, 0, "arrange: the emission itself hashed")
        watcher.scanNow()   // identity fast-path: same (dev, ino, size, mtime-ns) → no work
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit,
                       "arrange: identity fast-path active — counter flat")
        return (collector, hashesAfterEmit)
    }

    /// Review8 finding 2 (red-first): `lastEmittedIdentity` — the `.immutableAfterPublish`
    /// skip-hashing fast-path — was RETAINED across folder disappearance, so a remounted
    /// share or reused inode presenting the same name/size/cached timestamp suppressed a
    /// genuinely new sub forever (never re-hashed, never emitted). Deterministic shape:
    /// (1) emit with the fast-path active (counter flat); (2) REMOVE the watched folder;
    /// (3) mutate the file's CONTENT while preserving its full stat identity — same inode,
    /// same size, utimensat-restored mtime-ns; (4) RESTORE the same folder; (5) after
    /// recovery the file must be re-hashed EXACTLY once (counter +1) and EMITTED with the
    /// changed digest. Identities are location-bound and die with the folder generation.
    func testImmutablePolicy_folderReturn_sameIdentityDifferentContent_rehashedAndEmitted() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600,
                                   digestPolicy: .immutableAfterPublish)
        let url = tmp.appendingPathComponent("sub_001.fit")
        let (collector, hashesAfterEmit) = try await emitBaselineSubWithFastPathActive(url)

        // (2) The watched folder disappears (unmount/reconnect modeled as a move-aside).
        let emitted = FileIdentity.capture(url: url)!
        let aside = tmp.deletingLastPathComponent()
            .appendingPathComponent("watch-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: tmp, to: aside)
        watcher.scanNow()   // notices the disappearance — this folder generation ends

        // (3) Content changes while every stat field the fast-path trusts is preserved:
        // same inode (in-place write), same size, mtime-ns restored with utimensat — the
        // reused-inode/cached-attribute worst case on a reconnecting share.
        try mutateInteriorPreservingIdentity(aside.appendingPathComponent("sub_001.fit"),
                                             byteFromEnd: 64, identity: emitted)
        // (4) The same folder returns.
        try FileManager.default.moveItem(at: aside, to: tmp)
        watcher.scanNow()   // recovery re-arms + first post-return sighting (stat recorded)
        watcher.scanNow()   // stable → the dead generation's identity must NOT be trusted

        // (5) Exactly one rehash, and the changed content is EMITTED.
        let reEmitted = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(reEmitted,
                      "a same-identity, different-content file after a reconnect must be emitted")
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit + 1,
                       "…after exactly one rehash (the honest price of the reconnect)")
        let items = await collector.items
        XCTAssertEqual(items.count, 2)
        guard items.count >= 2 else { return }   // already failed above; don't trap on items[1]
        XCTAssertNotEqual(items[0].identity?.digest, items[1].identity?.digest,
                          "the post-return emission carries the CHANGED content digest")
        // The emission repopulated the fast-path for the NEW generation: flat again.
        watcher.scanNow()
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit + 1,
                       "fast-path re-established for the new folder generation")
    }

    /// Review8 finding 2, the true-duplicate half: the same disappear→return with IDENTICAL
    /// content. `lastEmittedDigest` is retained across the generation change (digests are
    /// content-bound), so the file is re-hashed exactly once but NOT re-emitted — dedup
    /// holds, and the dedup branch re-establishes the identity fast-path.
    func testImmutablePolicy_folderReturn_identicalContent_rehashedNotReEmitted() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600,
                                   digestPolicy: .immutableAfterPublish)
        let url = tmp.appendingPathComponent("sub_001.fit")
        let (collector, hashesAfterEmit) = try await emitBaselineSubWithFastPathActive(url)

        let aside = tmp.deletingLastPathComponent()
            .appendingPathComponent("watch-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: tmp, to: aside)
        watcher.scanNow()   // disappearance — generation ends
        try FileManager.default.moveItem(at: aside, to: tmp)   // identical content returns
        watcher.scanNow()   // recovery + first sighting
        watcher.scanNow()   // stable → re-hashed (the identity cache died with the generation)…
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit + 1,
                       "identical content is re-hashed exactly once after the reconnect")
        // …but the digest matches the emitted one → dedup holds, no re-emission.
        let reEmitted = await collector.waitForCount(2, timeout: 0.3)
        XCTAssertFalse(reEmitted, "identical content must NOT re-emit (digest dedup retained)")
        // The dedup branch re-records the identity: the fast-path is flat again.
        watcher.scanNow()
        XCTAssertEqual(watcher.digestComputations, hashesAfterEmit + 1,
                       "fast-path re-established by the dedup branch")
    }

    // MARK: - review10 item 3: bounded stop behind a stalled scan

    /// Review10 item 3 (pre-fix this test HANGS: stop() queue.sync'd behind the stalled
    /// scan and never returned — a liveness bug, so red-first is the hang itself): a scan
    /// stalled mid-file — modeled by parking the injected monotonic-clock read that sits
    /// between the digest and the emission, consistent with the existing seams — must not
    /// pin stop(). stop(timeout:) returns within its bound, logs the honest timeout line,
    /// and the abandoned scan observes the stop flag at its next check and exits WITHOUT
    /// emitting, with teardown following once the queue yields.
    func testStop_boundedBehindStalledScan_logsTimeout_noEmissionAfterStop() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock)
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        watcher.scanNow()                    // sighting
        watcher.scanNow()                    // stable → pending digest observation
        clock.advance(seconds: 3601)         // the NEXT scan would confirm the gate and EMIT

        // Stall that scan at its monotonic-clock read — after the hash, immediately
        // before the gate confirms and the emission would fire.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stalledOnce = NSLock_Flag()
        watcher.monotonicNowNanos = {
            if !stalledOnce.isSet {
                stalledOnce.set()
                entered.signal()
                release.wait()               // the scan is now wedged on the watcher queue
            }
            return clock.now()
        }
        let w = watcher!
        let scanDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { w.scanNow(); scanDone.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success,
                       "arrange: the scan is parked mid-file, pre-emission")

        // stop() must return within its bound even though the queue is wedged…
        let t0 = DispatchTime.now()
        w.stop(timeout: 0.3)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(elapsed, 3.0, "stop() must be bounded behind a stalled scan")
        XCTAssertTrue(logs.all.contains { $0.contains("watcher stop timed out behind a stalled read") },
                      "…and must log the timeout honestly — got \(logs.all)")

        // …and once the stall clears, the abandoned scan exits without emitting.
        release.signal()
        XCTAssertEqual(scanDone.wait(timeout: .now() + 5), .success,
                       "the abandoned scan must yield once the stall clears")
        try await Task.sleep(nanoseconds: 300_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty, "nothing may be emitted after stop()")
    }

    /// Review10 item 3, normal path: stop() on an idle watcher stays clean and prompt —
    /// no timeout line, terminal state honored (post-stop scans no-op).
    func testStop_idleWatcher_promptCleanNoTimeoutLog() throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600)
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        try watcher.start()
        let t0 = DispatchTime.now()
        watcher.stop()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(elapsed, 1.0, "an idle stop must be prompt")
        XCTAssertTrue(logs.all.isEmpty, "no timeout line on the clean path — got \(logs.all)")
        watcher.scanNow()   // terminal state: post-stop scan is a no-op (no crash, no emit)
    }

    // MARK: - review10 item 7: hostile public timing values

    /// Review10 item 7 (red-first: the pre-fix run TRAPPED in quietPeriodNanos'
    /// UInt64 conversion — a process crash, not a failure): quietPeriod/pollInterval are
    /// public Doubles feeding UInt64 monotonic conversion and DispatchTime arithmetic, so
    /// negative/NaN/infinite/huge values crashed the watcher. They must be sanitized at
    /// init — non-finite → the documented default, finite clamped into [0.01 s, 3600 s] —
    /// and the watcher must then run its normal gates and emit.
    func testHostileTimingValues_sanitizedAtInit_watcherStillEmits() async throws {
        for (i, bad) in [-1.0, Double.nan, .infinity, 1e30].enumerated() {
            let folder = tmp.appendingPathComponent("hostile-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let clock = ManualClock()
            let w = StackFileWatcher(folder: folder, quietPeriod: bad, pollInterval: bad,
                                     digestPolicy: .mutableStackerOutput)
            w.monotonicNowNanos = { clock.now() }
            defer { w.stop() }
            let collector = collect(w)
            try w.start()                  // pre-fix: NaN/∞ pollInterval crashed timer math
            try makeFITS(0.5).write(to: folder.appendingPathComponent("live_stack.fit"))
            w.scanNow()                    // sighting
            w.scanNow()                    // stable → digest gate (pre-fix: trap on quietPeriodNanos)
            clock.advance(seconds: 3601)   // covers every clamped/defaulted quiet period
            w.scanNow()                    // confirmed → emits
            let got = await collector.waitForCount(1, timeout: 5)
            XCTAssertTrue(got, "watcher with sanitized timing (\(bad)) must emit normally")
        }
    }

    /// Review4 P2 (mid-scan TOCTOU): the structural property of fd-relative enumeration, tested
    /// DETERMINISTICALLY with no timing. `scan()` validates the armed directory's (dev, ino) once,
    /// then enumerates — previously BY PATH, so a swap landing between the identity check and the
    /// enumeration applied old `lastSeenStat` observations to the NEW directory's files. The fix
    /// enumerates through the armed fd (`openat(fd, ".")` → `fdopendir` → `readdir`), which pins the
    /// OLD inode: a mid-scan swap is harmless BY CONSTRUCTION because the scan can only ever observe
    /// old-directory contents; the NEXT scan's identity check detects the swap and resets state.
    ///
    /// Proof: open an fd on dir A, atomically rename dir B over A's path (the exact mid-scan swap,
    /// frozen at its worst-case point), then enumerate via the still-open fd — it must return A's
    /// contents, not B's, even though the PATH now resolves to B. Called twice to prove each call
    /// uses a fresh read descriptor (no shared-offset residue on the armed O_EVTONLY fd).
    func testEnumerateDirectory_pinnedFDSeesOldContentsAcrossAtomicSwap() throws {
        // Dir A (at the "watched" path) with two entries.
        let a = tmp.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: a.appendingPathComponent("a1.fit"))
        try Data("a".utf8).write(to: a.appendingPathComponent("a2.fit"))
        // The armed fd — same open mode the watcher's DispatchSource uses.
        let fd = open(a.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "arrange: open(O_EVTONLY) on dir A")
        defer { close(fd) }

        // Dir B (same volume) with a different entry; atomically swap it over A's path.
        let b = tmp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: b.appendingPathComponent("b1.fit"))
        try Disruptor.atomicallySwapDirectory(at: a, with: b)

        // The PATH now resolves to B's contents…
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path), ["b1.fit"],
                       "arrange: the swap landed — the path resolves to the new directory")
        // …but the armed fd still pins A: fd-relative enumeration sees ONLY old-dir contents.
        XCTAssertEqual(StackFileWatcher.enumerateDirectory(fd: fd)?.sorted(), ["a1.fit", "a2.fit"],
                       "fd-relative enumeration must observe the OLD (pinned) directory, not the swapped-in one")
        // Repeatable: a second enumeration on the same armed fd returns the same listing.
        XCTAssertEqual(StackFileWatcher.enumerateDirectory(fd: fd)?.sorted(), ["a1.fit", "a2.fit"],
                       "each enumeration opens a fresh read descriptor — no offset residue across scans")
    }

    /// Review5 item 1 (single-descriptor per-file pipeline): the per-file open is fd-relative to
    /// the pinned directory, and stat + content reads all come from that ONE descriptor — tested
    /// deterministically at the exact worst-case point. Previously the size gate came from
    /// fstatat on the OLD inode while the header/digest reads reopened BY PATH: after a swap, the
    /// OLD (complete) size gated the completeness of a truncated NEW replacement, which could be
    /// emitted. With one pinned descriptor, stat, header, and digest all describe the same inode.
    func testOpenFile_pinnedDirectoryFDReadsOldFileAcrossAtomicSwap() throws {
        let full = makeFITS(0.5, size: 16)
        // Dir A (the "watched" path) holds the complete OLD file.
        let a = tmp.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try full.write(to: a.appendingPathComponent("live_stack.fit"))
        let fd = open(a.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "arrange: open(O_EVTONLY) on dir A")
        defer { close(fd) }

        // Dir B holds a same-name TRUNCATED replacement; atomically swap it over A's path.
        let b = tmp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let truncated = full.prefix(full.count / 2)
        try truncated.write(to: b.appendingPathComponent("live_stack.fit"))
        try Disruptor.atomicallySwapDirectory(at: a, with: b)

        // The PATH now resolves to the truncated replacement…
        let pathURL = a.appendingPathComponent("live_stack.fit")
        XCTAssertEqual(try Data(contentsOf: pathURL).count, truncated.count,
                       "arrange: the swap landed — the path resolves to the truncated new file")

        // …but the pinned per-file descriptor sees the OLD file for EVERYTHING the watcher
        // decides with: fstat size (the completeness gate) AND the content bytes (header/digest).
        let handle = try XCTUnwrap(StackFileWatcher.openFile(directoryFD: fd, name: "live_stack.fit"),
                                   "openat relative to the pinned dir fd must reach the old file")
        defer { try? handle.close() }
        let observed = try XCTUnwrap(StackFileWatcher.statFile(handle))
        XCTAssertEqual(observed.size, full.count,
                       "fstat on the pinned descriptor must report the OLD (complete) size")
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.readToEnd(), full,
                       "content reads on the pinned descriptor must see the OLD bytes — " +
                       "never a mixed-inode stat/content pair")
        // The mixed-inode failure mode, stated: the OLD size passing the completeness check
        // while PATH-based content reads hit the truncated NEW file.
        XCTAssertNotEqual(observed.size, truncated.count)
    }

    /// The producer (handle-streaming) and consumer (in-memory Data) digest forms must agree
    /// byte-for-byte, or consumer-side digest validation would reject every valid frame.
    /// Covers sub-chunk, multi-chunk-with-remainder, and exact-chunk-boundary sizes.
    func testContentDigest_handleAndDataFormsAgree() throws {
        for size in [1_000, 100_000, 131_072, 200_000] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let url = tmp.appendingPathComponent("digest-\(size).bin")
            try data.write(to: url)
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            XCTAssertEqual(FileIdentity.contentDigest(handle: fh, size: size),
                           FileIdentity.contentDigest(data: data),
                           "handle and data digest forms diverged for size \(size)")
        }
    }

    /// Review6 finding 2 — the digest must be a FULL-FILE content identity. The old head/tail
    /// sample missed any middle-only change, and for 64–128 KB files it hashed no tail at all.
    /// A same-size blob differing in ONE byte past the first 64 KB must digest differently, in
    /// BOTH forms. 100_000 bytes pins the 64–128 KB regression window specifically; 200_000
    /// pins the between-head-and-tail window of the old > 128 KB branch.
    func testContentDigest_middleOnlyMutationChangesDigest() throws {
        for size in [100_000, 200_000] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            var mutated = data
            mutated[80_000] ^= 0xFF   // past the 64 KB head, before any 64 KB tail
            XCTAssertNotEqual(FileIdentity.contentDigest(data: data),
                              FileIdentity.contentDigest(data: mutated),
                              "a middle-only mutation must change the digest (size \(size))")
            let url = tmp.appendingPathComponent("digest-mid-\(size).bin")
            try mutated.write(to: url)
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            XCTAssertEqual(FileIdentity.contentDigest(handle: fh, size: size),
                           FileIdentity.contentDigest(data: mutated),
                           "handle form must agree on the mutated bytes (size \(size))")
        }
    }

    /// Review6 finding 2, consumer side — a middle-only in-place mutation must fail digest
    /// validation even when the stat fields are captured FRESH (post-mutation), i.e. the digest
    /// alone must catch it. Under the head/tail-sample digest a 100 KB file's middle bytes were
    /// never hashed, so this read incorrectly succeeded.
    func testReadVerifying_middleOnlyMutationRefusedByDigest() throws {
        let size = 100_000
        let original = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = tmp.appendingPathComponent("mid-mutation.bin")
        try original.write(to: url)
        let originalDigest = FileIdentity.contentDigest(data: original)

        // Mutate ONE middle byte in place — same size.
        let fh = try FileHandle(forWritingTo: url)
        try fh.seek(toOffset: 80_000)
        try fh.write(contentsOf: Data([original[80_000] ^ 0xFF]))
        try fh.close()

        // Fresh stat (matches the mutated file) + the ORIGINAL content's digest: only the digest
        // stands between the consumer and the wrong bytes.
        let expected = try XCTUnwrap(FileIdentity.capture(url: url)).withDigest(originalDigest)
        XCTAssertThrowsError(try FileIdentity.read(url: url, verifying: expected)) {
            XCTAssertTrue($0 is FileIdentityMismatchError,
                          "full-file digest validation must refuse a middle-only mutation")
        }
    }

    /// Review6 finding 2, watcher side — a middle-only same-size change must NOT be suppressed
    /// by the digest-keyed dedup. A ~106 KB FITS (inside the 64–128 KB regression window) is
    /// emitted, then ONE pixel byte past the 64 KB head is flipped in place; after re-earning
    /// stability the file must emit AGAIN. Under the head/tail sample the digest was unchanged
    /// and the update was wrongly deduped.
    func testWatcher_middleOnlyChangeEmitsAgain_notDeduped() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let data = makeFITS(0.5, size: 160)   // 2880 header + 160*160*4 data ≈ 106 KB
        XCTAssertTrue(data.count > 65_536 && data.count < 131_072,
                      "arrange: file must sit in the 64–128 KB window (got \(data.count))")
        let url = tmp.appendingPathComponent("live_stack.fit")
        try data.write(to: url)
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "arrange: initial emission")

        // Flip one byte at offset 80,000 — inside the pixel data, past the 64 KB head, same size.
        let fh = try FileHandle(forWritingTo: url)
        try fh.seek(toOffset: 80_000)
        try fh.write(contentsOf: Data([data[80_000] ^ 0xFF]))
        try fh.close()

        let reEmitted = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(reEmitted, "a middle-only content change must re-emit, not be deduped")
        let items = await collector.items
        guard items.count >= 2 else { return }   // already failed above; don't trap on items[1]
        XCTAssertNotEqual(items[0].identity?.digest, items[1].identity?.digest,
                          "the two emissions must carry different content digests")
    }

    /// Emitted updates must carry the identity of the exact file version the watcher validated
    /// (dev/ino/size/mtime from its pinned descriptor, plus the content digest) — the consumer's
    /// only means of refusing a post-validation replacement.
    func testEmittedUpdateCarriesFileIdentityWithDigest() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let data = makeFITS(0.5)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try data.write(to: url)
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        let items = await collector.items
        let update = try XCTUnwrap(items.first)
        let identity = try XCTUnwrap(update.identity, "emitted update must carry a file identity")
        let now = try XCTUnwrap(FileIdentity.capture(url: url))
        XCTAssertTrue((identity.dev, identity.ino, identity.size, identity.mtimeSec, identity.mtimeNsec)
                      == (now.dev, now.ino, now.size, now.mtimeSec, now.mtimeNsec),
                      "identity must describe the file on disk (untouched since emission)")
        XCTAssertEqual(identity.digest, FileIdentity.contentDigest(data: data),
                       "identity must carry the watcher's content digest")
    }

    /// Review5 item 1, consumer side — deterministic replacement regression. The watcher
    /// validated file A; before the consumer reads, B is renamed over A's path. The consumer's
    /// verified read (fstat-compare on ITS OWN descriptor, decode from those bytes) must skip
    /// the frame with the honest log line — and the positive case must deliver the frame.
    func testConsumerFrame_replacedFileSkippedWithHonestLog_matchDelivered() throws {
        let old = makeFITS(0.3)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try old.write(to: url)
        let identity = try XCTUnwrap(FileIdentity.capture(url: url))
            .withDigest(FileIdentity.contentDigest(data: old))
        let update = StackUpdate(url: url, fileSize: old.count, identity: identity)

        // Positive: identity matches the file on disk → frame delivered, nothing logged.
        var logged: [String] = []
        XCTAssertNotNil(FolderFrameSource.frame(for: update, log: { logged.append($0) }),
                        "matching identity must deliver the frame")
        XCTAssertTrue(logged.isEmpty)

        // Replacement: rename a different (still-valid) FITS over A's path — new inode.
        let replacement = tmp.appendingPathComponent("replacement.fit")
        try makeFITS(0.9).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, url.path), 0, "arrange: atomic rename over the path")

        XCTAssertNil(FolderFrameSource.frame(for: update, log: { logged.append($0) }),
                     "a file replaced after validation must NOT be delivered")
        XCTAssertEqual(logged, ["file changed between validation and read — skipping live_stack.fit"],
                       "the skip must appear honestly in the log")
        // The same guard at the ImageLoader entry (SessionPipeline.handle's read path).
        XCTAssertThrowsError(try ImageLoader.load(url: url, expectedIdentity: identity)) { error in
            XCTAssertTrue(error is FileIdentityMismatchError)
        }
    }

    /// Digest is validated over the bytes the consumer ACTUALLY loaded — a stat-identical file
    /// whose digest disagrees is refused (strict content-version validation), and a nil expected
    /// identity preserves the legacy unverified read.
    func testReadVerifying_digestMismatchRefused_nilIdentityLegacyRead() throws {
        let data = makeFITS(0.4)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try data.write(to: url)
        let stat = try XCTUnwrap(FileIdentity.capture(url: url))

        // Correct digest → bytes delivered from the verified descriptor.
        let good = stat.withDigest(FileIdentity.contentDigest(data: data))
        XCTAssertEqual(try FileIdentity.read(url: url, verifying: good), data)
        // Digest-less identity (stat fields only) → stat check alone passes.
        XCTAssertEqual(try FileIdentity.read(url: url, verifying: stat), data)
        // Wrong digest with matching stat → refused.
        XCTAssertThrowsError(try FileIdentity.read(url: url, verifying: stat.withDigest("not-a-digest"))) {
            XCTAssertTrue($0 is FileIdentityMismatchError)
        }
        // nil identity → legacy read, no verification.
        XCTAssertEqual(try FileIdentity.read(url: url, verifying: nil), data)
    }

    /// Review6 finding 1 — identity revalidation around the verified read. Deterministic half:
    /// the file is mutated IN PLACE (same inode — unlike the rename-replacement test above)
    /// between capturing the identity and calling read; the fstat check must reject it. The
    /// post-read revalidation branch (a writer active DURING readToEnd) cannot be reached
    /// deterministically without an injectable read seam, which is not wanted — it is the same
    /// 4-line fstat+matches check exercised here, applied to the same descriptor after the read.
    func testReadVerifying_inPlaceMutationAfterCaptureRejected() throws {
        let data = makeFITS(0.4)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try data.write(to: url)
        let identity = try XCTUnwrap(FileIdentity.capture(url: url))
            .withDigest(FileIdentity.contentDigest(data: data))

        // Mutate in place: append one byte — same dev/ino, changed size (and mtime).
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data([0xFF]))
        try fh.close()

        XCTAssertThrowsError(try FileIdentity.read(url: url, verifying: identity)) {
            XCTAssertTrue($0 is FileIdentityMismatchError,
                          "an in-place mutation after validation must be refused by the fstat check")
        }
    }

    // MARK: - review11 findings 1+4: blocking-deadline write-off (redesigned cold1 C1 valve)

    /// Review11 finding 1 (P1, red-first — the reviewer's exact oscillator): _00001's stat
    /// identity changes on EVERY scan (touched/rewritten in place — the oscillating-SMB-
    /// metadata shape) while healthy _00002/_00003 wait behind it. Pre-fix every identity
    /// change reset the invalid write-off counter ("a rewrite is a new attempt"), so the
    /// oscillator never accrued a write-off and starved the whole session FOREVER, silently
    /// — this test's clock runs far past any plausible budget and pre-fix saw zero emissions
    /// and zero log lines. Post-fix the blocking deadline runs REGARDLESS of churn: identity
    /// changes do not reset it, the oscillator is written off once the budget elapses (one
    /// honest log line), and the healthy revisions emit in numeric order that same scan.
    func testMutablePolicy_oscillatingBlocker_identityChurnNeverResetsDeadline_writtenOff() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        try makeFITS(0.1, size: 16).write(to: url1)
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        let budget = Double(watcher.blockingBudgetNanos) / 1e9

        watcher.scanNow()   // sighting: _00001 fails to emit while blocking — its clock starts
        // Oscillate: rewrite _00001 before EVERY scan so its identity changes every scan,
        // stopping just short of the budget. No write-off, no emission — the hold is legal.
        var elapsed: TimeInterval = 0
        var i = 0
        while elapsed + 3601 < budget {
            i += 1
            try makeFITS(0.1 + Float(i % 7 + 1) * 0.01, size: 16).write(to: url1)
            clock.advance(seconds: 3601)
            elapsed += 3601
            watcher.scanNow()
        }
        let starvedWithinBudget = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(starvedWithinBudget,
                       "within the budget the oscillating blocker legitimately holds the series")
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "no write-off within the budget — got \(logs.all)")

        // Cross the deadline — the identity is STILL churning, and churn must not extend it.
        try makeFITS(0.9, size: 16).write(to: url1)
        clock.advance(seconds: 3602)
        watcher.scanNow()   // deadline passed → write-off → _00002/_00003 emit THIS scan
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "the oscillator must be written off at the deadline; higher revisions proceed")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00002.fit", "live_stack_00003.fit"],
                       "the healthy revisions emit in numeric order; the oscillator never does")
        let writeOffs = logs.all.filter { $0.contains("abandoning") }
        XCTAssertEqual(writeOffs.count, 1,
                       "the write-off must appear honestly in the log exactly once — got \(logs.all)")
        let writeOffLine = writeOffs.first ?? ""
        XCTAssertTrue(writeOffLine.contains("revision 00001 blocked emissions for")
                        && writeOffLine.contains("frame lost: live_stack_00001.fit"),
                      "the log names the revision, the blocked duration, and the frame loss — got \(writeOffs)")

        // Even if the oscillator settles later, it stays written off: no late emission,
        // no repeat log line.
        watcher.scanNow()
        clock.advance(seconds: 3601)
        watcher.scanNow()
        let after = await collector.items
        XCTAssertEqual(after.count, 2, "the written-off oscillator must never emit")
        XCTAssertEqual(logs.all.filter { $0.contains("abandoning") }.count, 1,
                       "the write-off line fires once, not per tick")
    }

    /// Review11 findings 1+4 (redesigned cold1 C1 corpse case): a permanently-invalid
    /// numbered revision (truncated _00001 — a producer crash) blocks _00002/_00003. The
    /// write-off is a HARD MONOTONIC DEADLINE on blocking-without-emitting: scan counts are
    /// irrelevant, only monotonic time counts. Inside the budget the corpse holds the series;
    /// past it the corpse is written off (one honest log line), the hold releases, the
    /// healthy revisions emit in order, and the high-water mark is NOT advanced by the
    /// write-off.
    func testMutablePolicy_permanentlyInvalidRevision_writtenOffAtDeadline_higherRevisionsProceed() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        // Truncated: header parses but declares more data than the file holds — the
        // structural-invalidity branch fires on every stable scan.
        try full.prefix(full.count / 2)
            .write(to: tmp.appendingPathComponent("live_stack_00001.fit"))
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        let budget = Double(watcher.blockingBudgetNanos) / 1e9

        watcher.scanNow()                 // sighting — _00001 becomes the blocker, clock starts
        watcher.scanNow()                 // stable: _00001 invalid; _00002/_00003 digests pending
        clock.advance(seconds: 3601)      // healthy pendings confirmable; deadline NOT reached
        watcher.scanNow()
        let heldWithinBudget = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(heldWithinBudget,
                       "within the blocking budget the invalid _00001 still holds the series")
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "no write-off within the budget — got \(logs.all)")

        clock.advance(seconds: budget)    // now safely past blockStart + budget
        watcher.scanNow()                 // deadline passed → write-off → _00002/_00003 emit
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "healthy revisions must proceed once the corpse is written off")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00002.fit", "live_stack_00003.fit"],
                       "the healthy revisions emit in numeric order; the corpse never does")
        let writeOffLines = logs.all.filter { $0.contains("abandoning") }
        XCTAssertEqual(writeOffLines.count, 1,
                       "the write-off must appear honestly in the log exactly once — got \(logs.all)")
        let line = writeOffLines.first ?? ""
        XCTAssertTrue(line.contains("revision 00001 blocked emissions for")
                        && line.contains("frame lost"),
                      "the log names the revision and admits the frame loss — got \(writeOffLines)")

        // Post-write-off scans stay silent: no repeat log, no late emission of _00001.
        clock.advance(seconds: 3601)
        watcher.scanNow()
        watcher.scanNow()
        let after = await collector.items
        XCTAssertEqual(after.count, 2, "the written-off revision must never emit")
        XCTAssertEqual(logs.all.filter { $0.contains("abandoning") }.count, 1,
                       "the write-off line fires once, not per tick")
    }

    /// Review11 finding 1, hard ceiling: a blocker that repeatedly reaches CONVERGING grace
    /// (the SAME pending digest observed again under a stable identity, quiet-period clock
    /// running) and then churns — over and over — is STILL written off by the total ceiling
    /// (budget + maxBlockerGraceExtensions × quietPeriod). Convergence renews only a short
    /// bounded grace; indefinite renewal through cycles of convergence and churn must be
    /// impossible, because the ceiling is enforced as a TOTAL-deadline check.
    func testMutablePolicy_convergingGraceRenewalCapped_writtenOffAtHardCeiling() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        try makeFITS(0.1, size: 16).write(to: url1)
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        let budget = Double(watcher.blockingBudgetNanos) / 1e9
        let ceiling = Double(watcher.blockingCeilingNanos) / 1e9

        watcher.scanNow()   // sighting: the blocker's clock starts
        // Cycle forever-converging churn: (1) stable scan records a fresh pending digest;
        // (2) the SAME digest is observed again inside the quiet period — CONVERGING, grace
        // renews; (3) the "writer" churns the file (new identity + digest). 1800 s per scan
        // keeps step (2) inside the 3600 s quiet period.
        var elapsed: TimeInterval = 0
        var cycle = 0
        while logs.all.filter({ $0.contains("abandoning") }).isEmpty, elapsed < ceiling + 4 * 5400 {
            cycle += 1
            clock.advance(seconds: 1800); elapsed += 1800
            watcher.scanNow()             // stable → pending recorded
            if !logs.all.filter({ $0.contains("abandoning") }).isEmpty { break }
            clock.advance(seconds: 1800); elapsed += 1800
            watcher.scanNow()             // same digest, quiet not elapsed → CONVERGING grace
            if !logs.all.filter({ $0.contains("abandoning") }).isEmpty { break }
            try makeFITS(0.1 + Float(cycle % 5 + 1) * 0.01, size: 16).write(to: url1)
            clock.advance(seconds: 1800); elapsed += 1800
            watcher.scanNow()             // churn: identity + digest changed
        }
        let writeOffs = logs.all.filter { $0.contains("abandoning") }
        XCTAssertEqual(writeOffs.count, 1,
                       "the hard ceiling must fire despite repeated converging grace — got \(logs.all)")
        XCTAssertGreaterThanOrEqual(elapsed, budget,
                                    "never written off before the budget (grace was honored)")
        XCTAssertLessThanOrEqual(elapsed, ceiling + 5400,
                                 "written off no later than the ceiling (+ one scan cycle of slack)")
        // The healthy _00002 proceeds once the capped blocker is written off.
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "_00002 must emit once the ceiling writes the blocker off")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["live_stack_00002.fit"])
    }

    /// Review11 finding 1 (the healthy counterpart): a genuinely progressing blocker that
    /// COMPLETES WITHIN THE BUDGET is never written off, and order holds — [1, 2, 3].
    /// (Replaces the cold1 pin that a churning blocker "holds indefinitely": churn is no
    /// longer unbounded-hold progress; the hold is bounded by the blocking budget.)
    func testMutablePolicy_blockerCompletesWithinBudget_neverWrittenOff_emitsInOrder() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        try makeFITS(0.1, size: 16).write(to: url1)
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        let budget = Double(watcher.blockingBudgetNanos) / 1e9
        watcher.scanNow()                 // sighting

        // _00001 is rewritten before a few scans (an in-progress write), all within budget.
        var elapsed: TimeInterval = 0
        for i in 0..<3 {
            try makeFITS(0.1 + Float(i + 1) * 0.01, size: 16).write(to: url1)
            clock.advance(seconds: 3601)
            elapsed += 3601
            watcher.scanNow()
        }
        XCTAssertLessThan(elapsed + 2 * 3601, budget,
                          "arrange: the whole completion fits inside the blocking budget")
        let premature = await collector.waitForCount(1, timeout: 0.3)
        XCTAssertFalse(premature, "_00002/_00003 stay held while _00001 is in progress")

        // _00001 settles → earns stability + the digest gate → all three emit in order.
        watcher.scanNow()                 // stable → digest pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                 // confirmed → [1, 2, 3]
        let got = await collector.waitForCount(3, timeout: 2)
        XCTAssertTrue(got, "all three revisions emit once the blocker completes within budget")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00001.fit", "live_stack_00002.fit", "live_stack_00003.fit"],
                       "order preserved — the hold was the point; no write-off inside the budget")
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "a blocker that completes within the budget is never written off — got \(logs.all)")
    }

    /// Review11 findings 1+4, recovery-before-deadline: an invalid revision that becomes
    /// valid well inside the blocking budget emits normally, in order, with no write-off log
    /// (the deadline never fires; nothing resets it either — it simply is not reached).
    func testMutablePolicy_invalidRevisionRecoversBeforeDeadline_emitsNormally() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        try full.prefix(full.count / 2).write(to: url1)   // truncated — invalid while stable
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        let budget = Double(watcher.blockingBudgetNanos) / 1e9

        watcher.scanNow()                 // sighting — the blocker's clock starts
        watcher.scanNow()                 // _00001 invalid; _00002 pending
        clock.advance(seconds: 3601)
        watcher.scanNow()                 // still blocked — but well inside the budget

        try full.write(to: url1)          // the producer finishes the file
        watcher.scanNow()                 // identity changed → re-earns stability
        watcher.scanNow()                 // stable → digest pending
        clock.advance(seconds: 3601)
        XCTAssertLessThan(2 * 3601.0, budget, "arrange: the recovery completes inside the budget")
        watcher.scanNow()                 // confirmed → _00001 emits, _00002 follows
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "a recovered revision emits normally")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00001.fit", "live_stack_00002.fit"])
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "no write-off for a file that recovered inside the budget — got \(logs.all)")
    }

    /// Review11 finding 4 (P2, red-first): the old write-off counted 5 consecutive invalid
    /// SCANS — at the supported 10 ms poll that elapsed in ~100 ms of wall time, discarding a
    /// recoverable paused write. Post-fix the write-off is monotonic-time-denominated: with a
    /// REAL 10 ms poll timer racing dozens of scans while the injected monotonic clock stands
    /// still, the paused (truncated) _00001 must NOT be written off — scan count is
    /// irrelevant — and once the producer resumes and completes the file inside the budget,
    /// both revisions emit in order.
    func testMutablePolicy_tinyPollInterval_pausedWriteNotWrittenOffByScanCount() async throws {
        let clock = ManualClock()
        let w = StackFileWatcher(folder: tmp, quietPeriod: 0.05, pollInterval: 0.01,
                                 fileNamePrefix: "live_stack",
                                 digestPolicy: .mutableStackerOutput)
        w.monotonicNowNanos = { clock.now() }
        watcher = w
        let logs = LogBox()
        w.onLog = { logs.append($0) }
        let collector = collect(w)
        let full = makeFITS(0.5, size: 64)
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        try full.prefix(full.count / 2).write(to: url1)   // the paused mid-write
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        try w.start()

        // Let the 10 ms poll run MANY scans (far beyond the old 5-scan threshold) while the
        // monotonic clock stands still: no write-off may occur — the budget has not elapsed.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "scan count is irrelevant — no write-off before the monotonic budget elapses; got \(logs.all)")
        let heldItems = await collector.items
        XCTAssertTrue(heldItems.isEmpty, "_00002 stays held while the paused _00001 blocks")

        // The producer resumes and completes the file — well inside the 30 s budget.
        try full.write(to: url1)
        try await Task.sleep(nanoseconds: 300_000_000)   // stability re-earned on real scans
        clock.advance(seconds: 1)                        // ≥ quietPeriod, << budget → gates confirm
        let got = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(got, "the recovered write emits — nothing was written off")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00001.fit", "live_stack_00002.fit"],
                       "the paused write recovers and order holds")
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "no write-off at any point — got \(logs.all)")
    }

    // MARK: - cold2 I1: the blocking deadline is EPISODE-scoped — lone time is never charged

    /// Cold2 I1 (P1, red-first — the reviewer's exact repro): _00001 blocks _00002 only
    /// BRIEFLY; _00002 vanishes; a long LONE period follows (nobody is blocked — the
    /// budget is on blocking-without-emitting, not on slowness, so a lone in-progress
    /// revision may take all night); then _00003 appears. Pre-fix the BlockTrack survived
    /// the lone period (cleared only on emission/absence/generation), so the lone wall
    /// time was charged to the deadline and _00001 was written off THE INSTANT _00003
    /// appeared. Post-fix each blocking episode runs a fresh clock: while blocksLater is
    /// false the track is cleared, so _00001 gets a full fresh budget, completes inside
    /// it, and emits in order — no write-off, no frame loss.
    func testMutablePolicy_loneBlockerPeriodNotCharged_freshClockPerBlockingEpisode() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        let url2 = tmp.appendingPathComponent("live_stack_00002.fit")
        try full.prefix(full.count / 2).write(to: url1)   // in-progress (invalid while stable)
        try makeFITS(0.2).write(to: url2)
        let ceiling = Double(watcher.blockingCeilingNanos) / 1e9

        watcher.scanNow()                 // _00001 blocks _00002 — its episode clock starts
        watcher.scanNow()                 // still blocking, briefly
        try FileManager.default.removeItem(at: url2)   // _00002 vanishes — nobody is blocked
        watcher.scanNow()                 // lone: blocksLater false → the episode is over

        // Long lone period, far past budget AND ceiling — this wall time must not count.
        clock.advance(seconds: ceiling + 10_000)
        watcher.scanNow()
        clock.advance(seconds: ceiling + 10_000)
        watcher.scanNow()
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "a lone in-progress revision starves nobody — never written off; got \(logs.all)")

        // A new blocking episode begins: _00003 appears. _00001 must get a FRESH budget,
        // not be written off instantly off the lone period's stale clock.
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        watcher.scanNow()                 // episode 2 starts — fresh clock
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "the returning blocker starts a fresh clock — no instant write-off; got \(logs.all)")

        // The producer completes _00001 well inside the fresh budget → [1, 3] in order.
        try full.write(to: url1)
        watcher.scanNow()                 // identity changed → re-earns stability
        clock.advance(seconds: 3601)
        watcher.scanNow()                 // stable → digest pending (and _00003 confirmable)
        clock.advance(seconds: 3601)
        watcher.scanNow()                 // digest confirmed → _00001 emits, _00003 follows
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "the blocker completes inside its FRESH budget and emits")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00001.fit", "live_stack_00003.fit"],
                       "order preserved — the fresh episode budget was honored")
        XCTAssertTrue(logs.all.filter { $0.contains("abandoning") }.isEmpty,
                      "no write-off anywhere in this run — got \(logs.all)")
    }

    /// Cold2 I1, log-honesty half: when a fresh episode DOES exhaust its budget, the
    /// write-off log reports the TRUE blocking duration — the current episode's hold,
    /// never the lone period's wall time (pre-fix heldSeconds spanned the lone period
    /// and was factually wrong).
    func testMutablePolicy_writeOffLogReportsEpisodeDuration_notLoneWallTime() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .mutableStackerOutput, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url1 = tmp.appendingPathComponent("live_stack_00001.fit")
        let url2 = tmp.appendingPathComponent("live_stack_00002.fit")
        try full.prefix(full.count / 2).write(to: url1)   // permanently truncated corpse
        try makeFITS(0.2).write(to: url2)
        let budget = Double(watcher.blockingBudgetNanos) / 1e9
        let ceiling = Double(watcher.blockingCeilingNanos) / 1e9
        let loneSeconds = 2 * ceiling + 20_000            // far larger than any budget

        watcher.scanNow()                 // episode 1: blocks _00002 briefly
        try FileManager.default.removeItem(at: url2)
        watcher.scanNow()                 // lone — episode over
        clock.advance(seconds: loneSeconds)
        watcher.scanNow()                 // still lone; the clock must not be charged

        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        watcher.scanNow()                 // episode 2 starts — fresh clock
        // The corpse never completes: run episode 2 past its own budget.
        var episodeElapsed: TimeInterval = 0
        while episodeElapsed <= budget + 3601,
              logs.all.filter({ $0.contains("abandoning") }).isEmpty {
            clock.advance(seconds: 3601)
            episodeElapsed += 3601
            watcher.scanNow()
        }
        let writeOffs = logs.all.filter { $0.contains("abandoning") }
        XCTAssertEqual(writeOffs.count, 1,
                       "episode 2 exhausts its own budget — exactly one write-off; got \(logs.all)")
        // Parse "blocked emissions for <N>s" and pin the duration to the EPISODE.
        let line = writeOffs.first ?? ""
        let held = Int(line.components(separatedBy: "blocked emissions for ").last?
            .components(separatedBy: "s ").first ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(Double(held), budget,
                                    "the write-off honors the full episode budget — got \(line)")
        XCTAssertLessThan(Double(held), loneSeconds,
                          "heldSeconds must report the EPISODE's hold, never the lone wall time — got \(line)")
        // The healthy revision proceeds once the corpse is written off.
        let got = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(got, "_00003 must emit once the corpse is written off")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["live_stack_00003.fit"])
    }

    // MARK: - cold1 I3: ordering machinery is .mutableStackerOutput-only

    /// Cold1 I3 (red-first): under `.immutableAfterPublish` numbered files are just files —
    /// order is irrelevant to stacking, and a bulk copy arriving out of numeric order
    /// (rsync/Finder/SMB visibility lag) must lose NOTHING. Pre-fix the high-water mark
    /// permanently dropped _00001.._00003 after _00100 emitted.
    func testImmutablePolicy_outOfOrderArrival_allEmit_noHoldsNoDrops() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .immutableAfterPublish, clock: clock,
                                        prefix: "live_stack")
        let logs = LogBox()
        watcher.onLog = { logs.append($0) }
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.9).write(to: tmp.appendingPathComponent("live_stack_00100.fit"))
        watcher.scanNow()                 // sighting
        watcher.scanNow()                 // stable → emits (immutable: no digest gate)
        let gotHigh = await collector.waitForCount(1, timeout: 2)
        XCTAssertTrue(gotHigh, "arrange: _00100 emits first")

        // The rest of the bulk copy becomes visible later — numerically BELOW _00100.
        for i in 1...3 {
            try makeFITS(Float(i) * 0.1).write(to: tmp.appendingPathComponent("live_stack_0000\(i).fit"))
        }
        watcher.scanNow()                 // sighting
        watcher.scanNow()                 // stable → ALL must emit (no mark, no holds)
        let got = await collector.waitForCount(4, timeout: 2)
        XCTAssertTrue(got, "an out-of-order bulk copy must lose nothing under the immutable policy")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00100.fit", "live_stack_00001.fit",
                        "live_stack_00002.fit", "live_stack_00003.fit"],
                       "all four frames delivered — numeric order within each scan")
        XCTAssertTrue(logs.all.filter { $0.contains("out of order") }.isEmpty,
                      "no out-of-order drops under the immutable policy — got \(logs.all)")
    }

    /// Cold1 C1 × I3, immutable half of the starvation repro: with ordering machinery
    /// scoped to the mutable policy, an invalid numbered file under `.immutableAfterPublish`
    /// never holds its neighbors at all — the healthy files emit on their first stable scan.
    func testImmutablePolicy_invalidNumberedFile_neverStarvesNeighbors() async throws {
        let clock = ManualClock()
        watcher = try makeManualWatcher(policy: .immutableAfterPublish, clock: clock,
                                        prefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        try full.prefix(full.count / 2)
            .write(to: tmp.appendingPathComponent("live_stack_00001.fit"))   // truncated forever
        try makeFITS(0.2).write(to: tmp.appendingPathComponent("live_stack_00002.fit"))
        try makeFITS(0.3).write(to: tmp.appendingPathComponent("live_stack_00003.fit"))
        watcher.scanNow()                 // sighting
        watcher.scanNow()                 // stable → the healthy pair emits immediately
        let got = await collector.waitForCount(2, timeout: 2)
        XCTAssertTrue(got, "an invalid file must not hold healthy neighbors under the immutable policy")
        let items = await collector.items
        XCTAssertEqual(items.map(\.url.lastPathComponent),
                       ["live_stack_00002.fit", "live_stack_00003.fit"])
    }
}
