import XCTest
@testable import LiveAstroCore

/// Task 2 of the fault-injection pillar (spec 2026-07-15): the file-boundary rows of the fault
/// matrix — FITS ingest, FrameRelay, RelayPruner, StackFileWatcher — driven with FaultKit against
/// the REAL filesystem. FITS reader and pruner boundaries predate a session, so they finish with
/// component-level honesty assertions (thrown error / no partial output / untouched). Relay and
/// watcher cells assert component behavior (skip/heal/log/survive).
///
/// Every cell corresponds to one row of docs/superpowers/fault-matrix.md. STOP-on-RED: a red cell
/// is a FOUND BUG, not a test to weaken — such cells are marked `// FOUND-BUG:` and reported.
final class FaultMatrixFileTests: XCTestCase {

    // MARK: - Shared helpers

    private func makeFITS(_ value: Float = 0.5, size: Int = 16) -> Data {
        FITSWriter.float32(width: size, height: size, channels: 1,
                           pixels: [Float](repeating: value, count: size * size))
    }

    /// Drive the relay's stability gate: first tick records the stat and defers; the copy happens
    /// on the next tick once the file is stable (mirrors FrameRelayTests.primeThenCopy).
    @discardableResult
    private func primeThenCopy(_ r: FrameRelay) throws -> Int {
        _ = try r.copyOnce()
        return try r.copyOnce()
    }

    /// Async collector over the watcher's update stream (mirrors StackFileWatcherTests.Collector).
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

    // ============================================================================================
    // MARK: FITS ingest row
    // ============================================================================================

    /// FITS × truncated: a valid header whose pixel data is cut at 60% → `FITSReader.read` throws
    /// (never returns a partial FITSImage). Component-level honesty: a thrown error, no partial
    /// output. (Pre-session boundary → no oracle; the "session continues" leg is the watcher cell
    /// below, which shows a valid frame still ingests afterward.)
    func testFITS_truncated_readerThrowsNoPartialImage() throws {
        let fs = try TempFS("fits-trunc"); defer { fs.tearDown() }
        let full = makeFITS(0.5, size: 32)
        let cut = Int(Double(full.count) * 0.60)
        let truncated = full.prefix(cut)
        XCTAssertLessThan(truncated.count, full.count, "arrange: data really is truncated")

        XCTAssertThrowsError(try FITSReader.read(Data(truncated))) { err in
            // Honest, specific error — not a silent partial or a generic crash.
            guard case FITSError.truncatedData = err else {
                return XCTFail("expected FITSError.truncatedData, got \(err)")
            }
        }
    }

    /// FITS × truncated (via watcher pipeline): a truncated FITS in the watched folder must be
    /// rejected (no emit — no partial output), and a subsequent COMPLETE write of the same file
    /// must still emit (the boundary rejected one frame; the pipeline continues). Component honesty:
    /// no partial output + recovery.
    func testFITS_truncated_watcherRejectsThenAcceptsComplete() async throws {
        let fs = try TempFS("fits-trunc-watch"); defer { fs.tearDown() }
        let watcher = StackFileWatcher(folder: fs.root, quietPeriod: 0.2, pollInterval: 0.3,
                                       fileNamePrefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start(); defer { watcher.stop() }

        let full = makeFITS(0.5, size: 64)
        let url = fs.root.appendingPathComponent("live_stack.fit")
        // Truncated: header claims full size but only 60% of the declared bytes are on disk.
        try Data(full.prefix(Int(Double(full.count) * 0.60))).write(to: url)
        // It must NOT emit — the completeness gate (size < minimumFileSize) rejects it.
        let premature = await collector.waitForCount(1, timeout: 1.5)
        XCTAssertFalse(premature, "watcher must not emit a truncated FITS (no partial output)")

        // A later COMPLETE write of a valid frame must be accepted — session continues.
        try full.write(to: url)
        let got1 = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got1, "a complete FITS after a rejected truncated one must still ingest")
    }

    /// FITS × mid-write: header written first (no pixels), then pixels appended — modeled with the
    /// CoordinatedWriter. The reader must reject the header-only intermediate (throws) and accept
    /// only the complete file → emitted exactly once, complete. Here we assert the READER contract
    /// directly (deterministic, no ticks): header-only → throws; header+pixels → parses complete.
    func testFITS_midWrite_readerRejectsHeaderOnlyAcceptsComplete() throws {
        let fs = try TempFS("fits-midwrite"); defer { fs.tearDown() }
        let full = makeFITS(0.5, size: 16)
        // The header is the first FITSReader.blockSize-aligned region ending at END; recompute it.
        let header = try FITSReader.readHeader(full)
        let headerOnly = full.prefix(header.headerBytes)

        let url = fs.root.appendingPathComponent("live_stack.fit")
        let writer = CoordinatedWriter(url: url); defer { writer.close() }

        // Step 1: emit header only.
        writer.writeChunk(Data(headerOnly))
        let midData = try Data(contentsOf: url)
        XCTAssertThrowsError(try FITSReader.read(midData)) { err in
            guard case FITSError.truncatedData = err else {
                return XCTFail("header-only mid-write must throw truncatedData, got \(err)")
            }
        }

        // Step 2: append the pixel section → file is now complete.
        writer.writeChunk(Data(full.suffix(from: header.headerBytes)))
        let fullData = try Data(contentsOf: url)
        let img = try FITSReader.read(fullData)   // must parse exactly once, complete
        XCTAssertEqual(img.width, 16)
        XCTAssertEqual(img.height, 16)
        XCTAssertEqual(img.pixels.count, 16 * 16, "complete file yields the full pixel plane")
    }

    /// FITS × invalid-replacement: the path where a FITS file is expected is instead a DIRECTORY
    /// named `x.fit`. Reading its bytes fails; the watcher must skip it with no emit and no crash.
    func testFITS_invalidReplacement_directoryNamedFit() async throws {
        let fs = try TempFS("fits-invalid"); defer { fs.tearDown() }

        // Reader leg: attempting to load a directory-as-file must fail (no partial image).
        let dirPath = fs.root.appendingPathComponent("live_stack.fit")
        try Disruptor.replaceWithDirectory(dirPath)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirPath.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "arrange: x.fit is a directory, not a file")
        // Data(contentsOf:) on a directory throws — the ingest boundary gets an error, not bytes.
        XCTAssertThrowsError(try Data(contentsOf: dirPath),
                             "reading a directory-as-FITS must throw (no partial bytes)")

        // Watcher leg: a directory entry named live_stack.fit must never emit, and a real file
        // later placed elsewhere still emits (boundary survives).
        let watcher = StackFileWatcher(folder: fs.root, quietPeriod: 0.2, pollInterval: 0.3,
                                       fileNamePrefix: "other")
        let collector = collect(watcher)
        try watcher.start(); defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 800_000_000)   // let the poll observe the bad entry
        let itemsAfterBadEntry = await collector.items
        XCTAssertTrue(itemsAfterBadEntry.isEmpty,
                      "a directory named x.fit must not produce an emit")
        try makeFITS(0.4).write(to: fs.root.appendingPathComponent("other_stack.fit"))
        let got2 = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got2, "a valid file after the bad entry must still ingest (boundary survives)")
    }

    // ============================================================================================
    // MARK: FrameRelay row
    // ============================================================================================

    /// Relay × mid-write/growing: a file grown across ticks is never published until stable, and
    /// the destination temp name (.<name>.relaytmp) is never visible under the glob mid-flight.
    func testRelay_midWriteGrowing_neverPublishedUntilStable_noTempLitter() throws {
        let fs = try TempFS("relay-grow"); defer { fs.tearDown() }
        let src = try fs.dir("src"), dst = try fs.dir("dst")
        let name = "Light_M 8_10.0s_LP_grow.fit"
        let srcFile = src.appendingPathComponent(name)
        let r = FrameRelay(source: src, destination: dst)
        let writer = CoordinatedWriter(url: srcFile); defer { writer.close() }

        func dstFitCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: dst.path)
                .filter { FrameRelay.wildcardMatch($0, "Light_*_10.0s_*.fit") }.count
        }

        // Tick 1: initial partial write present → deferred, nothing published.
        writer.writeChunk(Data(count: 100))
        XCTAssertEqual(try r.copyOnce(), 0, "first sighting of a partial file must not publish")
        XCTAssertEqual(try dstFitCount(), 0, "no matching file (nor temp) visible after tick 1")

        // Tick 2: grew between ticks → still deferred.
        writer.writeChunk(Data(count: 200))
        XCTAssertEqual(try r.copyOnce(), 0, "a file that grew between ticks must stay deferred")
        XCTAssertEqual(try dstFitCount(), 0, "still nothing visible under the glob after tick 2")

        // Tick 3: unchanged since tick 2 → stable → published complete (300 bytes).
        XCTAssertEqual(try r.copyOnce(), 1, "a file unchanged since the previous tick must publish")
        let published = dst.appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: published).count, 300, "published copy must be complete")
        // No temp litter: the only entry is the final file, no `.relaytmp`.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dst.path)
        XCTAssertFalse(entries.contains { $0.hasSuffix(".relaytmp") }, "no .relaytmp litter in dest")
    }

    /// Relay × truncated-dest: a pre-existing truncated destination + a stable source → healed once,
    /// with exactly one `relay healed` log line, then skipped thereafter.
    func testRelay_truncatedDest_healedOnceWithLog() throws {
        let fs = try TempFS("relay-heal"); defer { fs.tearDown() }
        let src = try fs.dir("src"), dst = try fs.dir("dst")
        let name = "Light_M 8_10.0s_LP_heal.fit"
        try Data(count: 300).write(to: src.appendingPathComponent(name))
        // Pre-place a truncated destination (crash/pre-fix aftermath).
        try Data(count: 100).write(to: dst.appendingPathComponent(name))
        let r = FrameRelay(source: src, destination: dst)
        var heals = 0
        r.onLog = { if $0.contains("relay healed truncated") { heals += 1 } }

        _ = try r.copyOnce()                       // prime: record stat, size mismatch keeps in play
        XCTAssertEqual(try r.copyOnce(), 1, "truncated dest must be healed and count as one relay")
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(name)).count, 300,
                       "healed dest must be full size")
        XCTAssertEqual(heals, 1, "exactly one heal log line")
        XCTAssertEqual(try r.copyOnce(), 0, "once healed, subsequent ticks skip the file")
        XCTAssertEqual(heals, 1, "no further heal log lines after the first heal")
    }

    /// Relay × deleted-mid-run: a matching source file seen (and deferred) on tick 1 is DELETED
    /// before tick 2 → no publish, no crash, and the pending stability entry is cleared (a file
    /// recreated with the SAME name must re-prime, not publish immediately from stale state).
    func testRelay_deletedMidRun_noPublishNoCrashPendingCleared() throws {
        let fs = try TempFS("relay-del"); defer { fs.tearDown() }
        let src = try fs.dir("src"), dst = try fs.dir("dst")
        let name = "Light_M 8_10.0s_LP_del.fit"
        let srcFile = src.appendingPathComponent(name)
        try Data(count: 128).write(to: srcFile)
        let r = FrameRelay(source: src, destination: dst)

        XCTAssertEqual(try r.copyOnce(), 0, "tick 1: record stat, defer")
        // Delete between the stability pass and the next tick.
        try Disruptor.deleteFile(srcFile)
        XCTAssertEqual(try r.copyOnce(), 0, "tick 2: source gone → nothing to publish, no crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(name).path),
                       "a deleted source must not have been published")

        // Recreate with the same name: pending state must have been cleared, so this must re-prime
        // (defer on first re-sighting) rather than publish from a stale lastSeen entry.
        try Data(count: 200).write(to: srcFile)
        XCTAssertEqual(try r.copyOnce(), 0, "recreated file must re-prime, not publish from stale state")
        XCTAssertEqual(try r.copyOnce(), 1, "then, once stable, it publishes")
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(name)).count, 200)
    }

    /// Relay × dir-removed: the SOURCE directory is removed mid-run → relay logs "source unreachable"
    /// and keeps ticking (no crash); restoring the dir with a fresh file resumes relaying.
    func testRelay_sourceDirRemoved_logsAndSurvivesThenResumes() throws {
        let fs = try TempFS("relay-dir"); defer { fs.tearDown() }
        let src = try fs.dir("src"), dst = try fs.dir("dst")
        let r = FrameRelay(source: src, destination: dst)
        var unreachable = 0
        r.onLog = { if $0.contains("source unreachable") { unreachable += 1 } }

        try Disruptor.removeDirectory(src)
        XCTAssertEqual(try r.copyOnce(), 0, "removed source dir → no publish, no crash")
        XCTAssertEqual(try r.copyOnce(), 0, "keeps ticking after removal")
        XCTAssertGreaterThanOrEqual(unreachable, 1, "removal must be logged (source unreachable)")

        // Restore the dir and drop a fresh matching file → relay resumes.
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data(count: 64).write(to: src.appendingPathComponent("Light_M 8_10.0s_LP_after.fit"))
        XCTAssertEqual(try primeThenCopy(r), 1, "relay resumes once the source dir is restored")
    }

    /// Relay × read-only dest (PROXY for ENOSPC/EIO): flip the dest dir read-only (probe first),
    /// so the staged copy into dest fails → logged as a retry, no crash, no temp litter; after
    /// restoring write permission the file relays. Chmod ineffective → skip with diagnostic.
    func testRelay_readOnlyDest_copyFailsLoggedRetriedNoLitter() throws {
        let fs = try TempFS("relay-rodest"); defer { fs.tearDown() }
        let src = try fs.dir("src"), dst = try fs.dir("dst")
        let name = "Light_M 8_10.0s_LP_ro.fit"
        try Data(count: 256).write(to: src.appendingPathComponent(name))
        let r = FrameRelay(source: src, destination: dst)
        var retries = 0
        r.onLog = { if $0.contains("retry next poll") { retries += 1 } }

        guard try Disruptor.makeReadOnly(dst, tempFS: fs) else {
            throw XCTSkip("chmod ineffective on this runner (privileged) — cannot exercise read-only dest")
        }
        // Prime (records stat) then the copying tick fails because the staged copy into the
        // read-only dest throws. Must not crash and must leave no partial/temp file behind.
        _ = try r.copyOnce()
        XCTAssertEqual(try r.copyOnce(), 0, "copy into a read-only dest must fail (0 published)")
        XCTAssertGreaterThanOrEqual(retries, 1, "the failed copy must be logged for retry")
        let entriesRO = try FileManager.default.contentsOfDirectory(atPath: dst.path)
        XCTAssertFalse(entriesRO.contains { $0.hasSuffix(".relaytmp") }, "no temp litter after a failed copy")

        // Restore write permission → the retry succeeds. The source has been stable since the
        // first tick, so lastSeen already matches; the very next tick copies. Sum two ticks so we
        // don't depend on WHICH of them does the (single) copy.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: dst.path)
        let relayedAfterRestore = try r.copyOnce() + r.copyOnce()
        XCTAssertEqual(relayedAfterRestore, 1, "after restoring write permission the file relays exactly once")
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(name)).count, 256)
    }

    // ============================================================================================
    // MARK: RelayPruner row
    // ============================================================================================

    /// Pruner × read-only (PROXY for ENOSPC/undeletable): an old name-dated session dir made
    /// read-only inside the relay root → prune skips it best-effort (does not throw), and still
    /// removes a sibling old dir that IS deletable. Chmod ineffective → skip with diagnostic.
    func testPruner_readOnlySessionDir_skippedBestEffortOthersRemoved() throws {
        let fs = try TempFS("prune-ro"); defer { fs.tearDown() }
        let root = try fs.dir("relay-root")
        // Two old sessions (older than the cutoff). One will be made read-only.
        let locked = try fs.dir("relay-root/M31-2020-01-01")
        let deletable = try fs.dir("relay-root/M42-2020-01-02")
        try Data(count: 16).write(to: locked.appendingPathComponent("frame.fit"))
        try Data(count: 16).write(to: deletable.appendingPathComponent("frame.fit"))

        // Make the locked session's PARENT contents undeletable by flipping the dir read-only.
        guard try Disruptor.makeReadOnly(locked, tempFS: fs) else {
            throw XCTSkip("chmod ineffective on this runner (privileged) — cannot exercise undeletable dir")
        }
        // Removing a dir whose own permission is read-only fails when it has children; ensure the
        // child is protected too by making the child unremovable via the read-only parent.
        // prune must not throw; it returns the sibling it COULD remove.
        let removed = RelayPruner.prune(root: root, olderThanDays: 30,
                                        now: Date(timeIntervalSince1970: 1_700_000_000))
        let names = Set(removed.map { $0.name })
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path),
                      "a read-only (undeletable) session dir must be skipped, not removed")
        XCTAssertTrue(names.contains("M42-2020-01-02"), "the deletable old sibling must still be removed")
        XCTAssertFalse(names.contains("M31-2020-01-01"), "the undeletable dir must not be reported removed")
    }

    /// Pruner × invalid-replacement: a dangling symlink entry in the relay root (name would parse
    /// as a dated session) → skipped because isDirectory is false, and left untouched (no throw).
    func testPruner_danglingSymlinkEntry_skippedUntouched() throws {
        let fs = try TempFS("prune-symlink"); defer { fs.tearDown() }
        let root = try fs.dir("relay-root")
        // A dangling symlink whose NAME is a valid old dated session token.
        let link = root.appendingPathComponent("M13-2020-03-03")
        try Disruptor.replaceWithDanglingSymlink(link)
        // Also a genuine old dir, to prove the pruner still does its job around the bad entry.
        _ = try fs.dir("relay-root/M27-2020-03-04")

        let removed = RelayPruner.prune(root: root, olderThanDays: 30,
                                        now: Date(timeIntervalSince1970: 1_700_000_000))
        let names = Set(removed.map { $0.name })
        XCTAssertFalse(names.contains("M13-2020-03-03"),
                       "a symlink (isDirectory false) must be skipped, not pruned")
        // The symlink entry itself must still exist (untouched).
        let stillThere = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        XCTAssertTrue(stillThere, "the dangling symlink entry must be left untouched")
        XCTAssertTrue(names.contains("M27-2020-03-04"), "a real old dir is still pruned")
    }

    // ============================================================================================
    // MARK: StackFileWatcher row
    // ============================================================================================

    /// Watcher × mid-write/growing: a preallocated (full declared size) file whose mtime keeps
    /// bumping is NOT emitted until it stabilizes, then emits exactly once. (Systematizes the
    /// existing testIgnoresPreallocatedFITSUntilStable.)
    func testWatcher_midWriteGrowing_notEmittedUntilStable() async throws {
        let fs = try TempFS("watch-grow"); defer { fs.tearDown() }
        let watcher = StackFileWatcher(folder: fs.root, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start(); defer { watcher.stop() }

        let full = makeFITS(0.5, size: 64)
        let url = fs.root.appendingPathComponent("live_stack.fit")
        try full.write(to: url)                       // full declared size immediately (preallocated)
        // Keep bumping mtime as if pixels are written in place (same size, new mtime → not stable).
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let fh = try FileHandle(forWritingTo: url)
            try fh.seek(toOffset: 0); fh.write(full); try fh.close()
        }
        let premature = await collector.waitForCount(1, timeout: 0.1)
        XCTAssertFalse(premature, "must not emit a preallocated file while still being written")
        // Stop touching it → stabilizes → emits once.
        let gotStable = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(gotStable, "a stabilized file must emit")
        try await Task.sleep(nanoseconds: 800_000_000)
        let stableCount = await collector.items.count
        XCTAssertEqual(stableCount, 1, "a stabilized file emits exactly once")
    }

    /// Watcher × deleted-mid-run: a file that appears, stabilizes and emits, is then DELETED. The
    /// watcher must not crash, must not emit again for it, and a DIFFERENT file appearing afterward
    /// must still emit (the boundary survives a mid-run deletion).
    func testWatcher_deletedMidRun_noCrashNextFileFine() async throws {
        let fs = try TempFS("watch-del"); defer { fs.tearDown() }
        let watcher = StackFileWatcher(folder: fs.root, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start(); defer { watcher.stop() }

        let a = fs.root.appendingPathComponent("live_stack.fit")
        try makeFITS(0.3).write(to: a)
        let firstEmit = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(firstEmit, "first file emits")

        try Disruptor.deleteFile(a)                   // delete mid-run
        try await Task.sleep(nanoseconds: 600_000_000)

        // A different file must still be ingested — the watcher survived the deletion.
        try makeFITS(0.7).write(to: fs.root.appendingPathComponent("next_stack.fit"))
        let secondEmit = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(secondEmit,
                      "a new file after a deletion must still emit (watcher survived)")
    }

    /// Watcher × dir-removed: the watched folder is removed mid-run.
    ///
    /// Full invariant (FOUND-BUG #1, now fixed):
    /// (a) The watcher must log ONCE that the folder disappeared — not every tick.
    /// (b) When the folder is recreated, the SAME live watcher must resume (re-arm
    ///     the DispatchSource fd) and successfully ingest a new FITS dropped in.
    /// (c) No crash throughout; no spurious emit for the vanished baseline file.
    /// (d) stop() after disappearance is a no-op / no crash.
    func testWatcher_dirRemoved_logsOnceAndResumesOnRecreate() async throws {
        let fs = try TempFS("watch-dir"); defer { fs.tearDown() }
        let folder = try fs.dir("watched")
        let watcher = StackFileWatcher(folder: folder, quietPeriod: 0.2, pollInterval: 0.3)

        // Capture all log lines through the onLog seam (mirrors FrameRelay).
        var logLines: [String] = []
        watcher.onLog = { msg in logLines.append(msg) }

        let collector = collect(watcher)
        try watcher.start()

        // Baseline: emit a valid FITS before the disruption.
        try makeFITS(0.4).write(to: folder.appendingPathComponent("live_stack.fit"))
        let baselineEmit = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(baselineEmit, "baseline file emits before disruption")

        // --- Disruption: remove the watched folder ---
        try Disruptor.removeDirectory(folder)
        // Let several poll ticks fire against the missing folder.
        try await Task.sleep(nanoseconds: 800_000_000)

        // (a) Log exactly once — not every tick.
        let disappearedLines = logLines.filter { $0.contains("watched folder disappeared") }
        XCTAssertEqual(disappearedLines.count, 1,
                       "must log exactly once that the folder disappeared (not every tick); got: \(logLines)")

        // (c) No spurious emit.
        let afterRemovalCount = await collector.items.count
        XCTAssertEqual(afterRemovalCount, 1, "no spurious emit after the folder vanished")

        // --- Recovery: recreate the folder and drop a new FITS ---
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Give the poll timer time to notice the folder returned and re-arm.
        try await Task.sleep(nanoseconds: 800_000_000)

        // (b) Log that the folder returned (same live watcher).
        let returnedLines = logLines.filter { $0.contains("watched folder returned") }
        XCTAssertGreaterThanOrEqual(returnedLines.count, 1,
                                    "must log that the folder returned; got: \(logLines)")

        // (b) Drop a fresh FITS — the live watcher (not a new one) must emit it.
        try makeFITS(0.6).write(to: folder.appendingPathComponent("live_stack2.fit"))
        let recoveryEmit = await collector.waitForCount(2, timeout: 8)
        let recoveryCount = await collector.items.count
        XCTAssertTrue(recoveryEmit,
                      "SAME live watcher must emit after folder recreated (recovery proven); items=\(recoveryCount)")

        // (d) stop() after disappearance/recovery must not crash.
        watcher.stop()
    }

    /// Watcher × folder replacement (F2, review2): a same-name file recreated after the watched
    /// folder disappears must NOT inherit the vanished file's pending stability observation. Before
    /// the fix, `lastSeenStat` survived the disappearance, so a recreated same-name file whose
    /// (size, mtime) matched the last observation passed the two-tick stability gate on its FIRST
    /// post-return sighting — publishing a possibly-in-progress FITS. After the fix the pending map
    /// is cleared on disappearance (emitted-digest retained for dedup), so the recreated file must
    /// re-earn stability across ticks before it emits.
    ///
    /// Deterministic reproduction: the recreated file is given the SAME size and (via setAttributes)
    /// the SAME mtime as the vanished baseline — the exact coarse-mtime collision the finding calls
    /// out — but DIFFERENT content (different digest, so dedup does not mask the stability gate). It
    /// must not emit on the first post-return sighting; once stable across a tick, it emits exactly
    /// once.
    func testWatcher_folderReplaced_sameNameFileReEarnsStabilityNotEmittedEarly() async throws {
        let fs = try TempFS("watch-replace"); defer { fs.tearDown() }
        let folder = try fs.dir("watched")
        let pollInterval: TimeInterval = 0.4
        let watcher = StackFileWatcher(folder: folder, quietPeriod: 0.1, pollInterval: pollInterval,
                                       fileNamePrefix: "live_stack")
        let collector = collect(watcher)

        // Timestamp the "folder returned" log and the replacement's emit so we can prove the emit
        // did NOT happen in the same scan tick that saw the folder return (it re-earned stability).
        let clock = FolderReplaceClock()
        watcher.onLog = { msg in if msg.contains("watched folder returned") { clock.markReturned() } }
        try watcher.start(); defer { watcher.stop() }

        // Baseline: a complete FITS emits, and its (size, mtime) become the pending/last-seen stat.
        let name = "live_stack.fit"
        let url = folder.appendingPathComponent(name)
        let baseline = makeFITS(0.4, size: 64)
        try baseline.write(to: url)
        let baselineEmit = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(baselineEmit, "baseline file emits")
        let baselineMtime = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as! Date

        // Disruption: remove the whole watched folder (clears pending stability under the fix).
        try Disruptor.removeDirectory(folder)
        try await Task.sleep(nanoseconds: 900_000_000)   // let poll ticks notice the disappearance

        // Recovery: recreate the folder with the replacement ALREADY inside, so the return scan sees
        // the folder-plus-file atomically in one tick (no interleaving where the return tick sees an
        // empty folder — that would let the buggy code's first-sighting emit land a tick later and
        // spuriously pass). Stage a sibling dir containing a DIFFERENT-content, SAME-name, SAME-size
        // file whose mtime is forced to the vanished baseline's — the exact coarse-mtime collision the
        // finding calls out — then rename the whole dir into place. Different pixels → different digest,
        // so dedup does not mask the stability gate.
        let staged = fs.root.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let replacement = makeFITS(0.9, size: 64)
        XCTAssertEqual(replacement.count, baseline.count, "arrange: replacement is the same size")
        let stagedFile = staged.appendingPathComponent(name)
        try replacement.write(to: stagedFile)
        try FileManager.default.setAttributes([.modificationDate: baselineMtime],
                                              ofItemAtPath: stagedFile.path)
        try FileManager.default.moveItem(at: staged, to: folder)   // atomic folder-with-file return
        clock.markReplacementWritten()

        // The replacement must emit (recovery works), but only AFTER re-earning stability — i.e. not
        // in the same scan tick that first re-sees it. We prove that by the emit timestamp lagging the
        // "folder returned" mark by at least ~one poll interval. Without the fix, the stale (size,
        // mtime) match fires an emit in the very first post-return sighting (same tick as the return),
        // so the gap would be ~0.
        let emittedAfterStable = await collector.waitForCount(2, timeout: 6)
        XCTAssertTrue(emittedAfterStable, "the replacement must emit once it re-earns stability")
        clock.markEmit()

        let gap = clock.returnToEmitGap()
        XCTAssertGreaterThanOrEqual(gap, pollInterval * 0.8,
            "F2: recreated same-name/size/mtime file must re-earn stability across a tick, not emit in the return tick (gap \(gap)s < ~one poll interval)")
    }

    /// Thread-safe timestamp collector for the folder-replacement stability test: the watcher's log
    /// fires on its serial queue while the test thread reads — lock-protect (F5 pattern).
    private final class FolderReplaceClock {
        private let lock = NSLock()
        private var returnedAt: Date?
        private var replacementAt: Date?
        private var emitAt: Date?
        func markReturned() { lock.lock(); if returnedAt == nil { returnedAt = Date() }; lock.unlock() }
        func markReplacementWritten() { lock.lock(); replacementAt = Date(); lock.unlock() }
        func markEmit() { lock.lock(); if emitAt == nil { emitAt = Date() }; lock.unlock() }
        /// Seconds between the LATER of (folder-returned, replacement-written) and the emit. Using the
        /// later of the two avoids counting time before the replacement even existed on disk.
        func returnToEmitGap() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            let start = max(returnedAt ?? .distantPast, replacementAt ?? .distantPast)
            guard let emit = emitAt, start > .distantPast else { return 0 }
            return emit.timeIntervalSince(start)
        }
    }

    /// stop() during the missing-folder window must be a no-op (no crash, idempotent).
    func testWatcher_stopAfterDirRemoved_noCrash() async throws {
        let fs = try TempFS("watch-stop-missing"); defer { fs.tearDown() }
        let folder = try fs.dir("watched")
        let watcher = StackFileWatcher(folder: folder, quietPeriod: 0.2, pollInterval: 0.3)
        try watcher.start()
        try Disruptor.removeDirectory(folder)
        try await Task.sleep(nanoseconds: 400_000_000)   // let at least one poll fire
        watcher.stop()   // must not crash
        watcher.stop()   // idempotent — must not crash
    }
}
