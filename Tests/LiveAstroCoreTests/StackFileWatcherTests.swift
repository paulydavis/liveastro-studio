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
    /// Covers both branches: small file (head only) and > 128 KB (head + tail chunks).
    func testContentDigest_handleAndDataFormsAgree() throws {
        for size in [1_000, 200_000] {
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
}
