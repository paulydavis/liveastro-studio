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
                                   clock: ManualClock) throws -> StackFileWatcher {
        let w = StackFileWatcher(folder: tmp, quietPeriod: 3600, pollInterval: 3600,
                                 digestPolicy: policy)
        w.monotonicNowNanos = { clock.now() }
        return w
    }

    /// Review8 finding 1 (red-first): stat stability is satisfied while an in-place
    /// rewriter PAUSES mid-rewrite (size unchanged, mtime coarse/restored), so pre-fix the
    /// watcher hashed the temporary A/B hybrid and emitted it immediately — and the
    /// consumer then correctly verified that exact hybrid, because digest verification
    /// proves byte identity, not producer completeness. The digest-stability gate must
    /// hold a NEW digest as pending and emit only when the SAME digest is observed again
    /// at least `quietPeriod` of MONOTONIC time later; a DIFFERENT digest on a later scan
    /// replaces the pending one, still unemitted. The unfinished hybrid's digest must
    /// never be emitted.
    func testMutablePolicy_midRewritePause_hybridNeverEmitted() async throws {
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
}
