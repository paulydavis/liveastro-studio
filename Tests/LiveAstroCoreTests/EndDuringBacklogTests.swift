import XCTest
@testable import LiveAstroCore

/// Reproduction for the manual test-3 anomaly: a live session on a folder holding 3 subs
/// recorded only 2 — the third appeared in neither the stacked nor the rejected record.
final class EndDuringBacklogTests: XCTestCase {

    func testCompletedImportDoesNotReportAnIncompleteLiveRelay() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeSub(subs, "Light_001.fit", dx: 0)
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "Import", telescope: "T", camera: "C",
                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                subExposureSeconds: 180, notes: ""),
            rootDirectory: sandbox.appendingPathComponent("sessions"))
        let logs = Box()
        pipeline.onLog = { logs.add($0) }
        try pipeline.start()
        let dir = try pipeline.end()
        let base = dir.hasDirectoryPath ? dir : dir.deletingLastPathComponent()
        let summary = try String(contentsOf: base.appendingPathComponent("session-summary.md"), encoding: .utf8)
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
        XCTAssertNil(manifest.sourceAccountingComplete,
                     "finite imports must not persist live-relay accounting")
        XCTAssertFalse(summary.contains("INCOMPLETE"), summary)
        XCTAssertFalse(logs.all.contains { $0.contains("accounting is INCOMPLETE") })
    }

    func testRelayCompletionWakesAllConcurrentWaiters() {
        let counters = IntakeCounters()
        let ready = DispatchSemaphore(value: 0)
        let finished = expectation(description: "all waiters returned")
        finished.expectedFulfillmentCount = 8
        let results = UncheckedBox(0)
        let resultLock = NSLock()
        for _ in 0..<8 {
            DispatchQueue.global().async {
                ready.signal()
                let complete = counters.awaitRelayCompletion(timeout: .now() + 2)
                if complete { resultLock.withLock { results.value += 1 } }
                finished.fulfill()
            }
        }
        for _ in 0..<8 { XCTAssertEqual(ready.wait(timeout: .now() + 5), .success) }
        // Allow the dispatched callers to enter their waits before completing the relay.
        Thread.sleep(forTimeInterval: 0.1)
        counters.noteRelayFinished()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(results.value, 8)
        XCTAssertTrue(counters.snapshot.accountingComplete)
    }

    private func writeSub(_ dir: URL, _ name: String, dx: Double) throws {
        var px = [Float](repeating: 0.02, count: 256 * 256)
        for i in 0..<20 {
            let sx = Double((i * 47) % 230 + 12) + dx, sy = Double((i * 83) % 230 + 12)
            for y in max(0, Int(sy) - 6)...min(255, Int(sy) + 6) {
                for x in max(0, Int(sx) - 6)...min(255, Int(sx) + 6) {
                    let ddx = Double(x) - sx, ddy = Double(y) - sy
                    px[y * 256 + x] += 0.8 * Float(exp(-(ddx * ddx + ddy * ddy) / 8))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    private final class UncheckedBox<T>: @unchecked Sendable {
        private let lock = NSLock(); private var v: T
        init(_ v: T) { self.v = v }
        var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
        var count: Int { lock.withLock { v.count } }
    }

    private func run(endAfterFrames: Int) throws -> (recorded: [String], csvRows: [String], logs: [String], summary: String, filesOnDisk: [String]) {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try writeSub(subs, "Light_001.fit", dx: 0)
        try writeSub(subs, "Light_002.fit", dx: 1.5)
        try writeSub(subs, "Light_003.fit", dx: 3.0)

        let source = FolderFrameSource(folder: subs, mode: .live, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "Backlog", telescope: "T", camera: "C",
                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                subExposureSeconds: 180, notes: ""),
            rootDirectory: sessions)

        let seen = Box()
        let logs = Box()
        pipeline.onLog = { logs.add($0) }
        let reached = expectation(description: "frames processed")
        pipeline.onSubFrame = { rec in
            seen.add(rec.sourceFile)
            if seen.count == endAfterFrames { reached.fulfill() }
        }
        try pipeline.start()
        wait(for: [reached], timeout: 30)
        let dir = try pipeline.end()

        // end() may return the session dir or a file inside it; find sub-frames.csv either way.
        let base = dir.hasDirectoryPath ? dir : dir.deletingLastPathComponent()
        var rows: [String] = []
        if let csv = try? String(contentsOf: base.appendingPathComponent("sub-frames.csv"), encoding: .utf8) {
            rows = csv.split(separator: "\n").dropFirst().map(String.init)
        }
        let summary = (try? String(contentsOf: base.appendingPathComponent("session-summary.md"), encoding: .utf8)) ?? ""
        let stillOnDisk = (try? FileManager.default.contentsOfDirectory(atPath: subs.path))?
            .filter { $0.hasSuffix(".fit") }.sorted() ?? []
        return (seen.all, rows, logs.all, summary, stillOnDisk)
    }

    /// Baseline: left alone, all three must be recorded — and nothing is claimed to be lost.
    func testAllThreePreExistingSubsAreRecordedWhenAllowedToFinish() throws {
        let r = try run(endAfterFrames: 3)
        XCTAssertEqual(r.csvRows.count, 3, "recorded \(r.recorded)")
        XCTAssertFalse(r.logs.contains { $0.contains("not processed before the session ended") },
                       "nothing was left unprocessed, so nothing may be reported: \(r.logs)")
        XCTAssertFalse(r.summary.contains("not processed before the session ended"),
                       "a clean session's summary must not carry the row")
    }

    /// The manual case (2026-09-10): End pressed while a sub the watcher had ALREADY
    /// admitted was still buffered. `LivePull.nextFrame()` returns nil as soon as `stopped`
    /// is set, so that sub is never pulled — it reaches neither the stacked nor the rejected
    /// record, and nothing said so.
    ///
    /// Deterministic by construction, not by timing:
    ///   * the consumer is PARKED inside the second sub's callback, so a third can never be
    ///     pulled while the test sets up;
    ///   * admission of all three is ASSERTED before End is called;
    ///   * End runs on another thread and the park is released only once `stop()` has been
    ///     stopped the puller, so the third cannot be pulled afterwards either.
    ///
    /// The session is not required to stack it — draining on End is a separate policy
    /// question. It IS required to account for it.
    func testSubsLeftUnprocessedAtEndAreReportedAndFilesRemain() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeSub(subs, "Light_001.fit", dx: 0)
        try writeSub(subs, "Light_002.fit", dx: 1.5)
        try writeSub(subs, "Light_003.fit", dx: 3.0)

        let source = FolderFrameSource(folder: subs, mode: .live, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "Backlog", telescope: "T", camera: "C",
                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                subExposureSeconds: 180, notes: ""),
            rootDirectory: sessions)

        let seen = Box(), logs = Box()
        pipeline.onLog = { logs.add($0) }
        let heldAtTwo = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pipeline.onSubFrame = { rec in
            seen.add(rec.sourceFile)
            if seen.count == 2 {
                heldAtTwo.signal()
                // Park the consumer HERE: with this thread stopped between frames, no
                // further pull can happen until the test allows it.
                _ = release.wait(timeout: .now() + 60)
            }
        }
        try pipeline.start()
        XCTAssertEqual(heldAtTwo.wait(timeout: .now() + 60), .success, "two frames must process")

        // Barrier 1: all three updates admitted, exactly two handed on.
        let admitDeadline = Date().addingTimeInterval(30)
        while source.intakeSnapshot.admitted < 3 && Date() < admitDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(source.intakeSnapshot.admitted, 3, "all three must be admitted BEFORE End")
        XCTAssertEqual(source.intakeSnapshot.delivered, 2, "the third must still be unpulled")

        // Barrier 2: End on another thread; release the park only once stop() has been
        // stopped the puller, so the third can never be pulled after the barrier either.
        let ended = expectation(description: "end() returned")
        let dirBox = UncheckedBox<URL?>(nil)
        let errBox = UncheckedBox<Error?>(nil)
        DispatchQueue.global().async {
            do { dirBox.value = try pipeline.end() } catch { errBox.value = error }
            ended.fulfill()
        }
        let stopDeadline = Date().addingTimeInterval(30)
        while !source.livePullIsStopped && Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(source.livePullIsStopped, "pulling must be stopped before release")
        release.signal()
        wait(for: [ended], timeout: 90)
        XCTAssertNil(errBox.value, "end() failed: \(String(describing: errBox.value))")
        let dir = try XCTUnwrap(dirBox.value)

        let base = dir.hasDirectoryPath ? dir : dir.deletingLastPathComponent()
        let csv = (try? String(contentsOf: base.appendingPathComponent("sub-frames.csv"), encoding: .utf8)) ?? ""
        let rows = csv.split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 2, "exactly two frames processed")

        let report = logs.all.filter { $0.contains("not processed before the session ended") }
        XCTAssertEqual(report.count, 1, "exactly one report expected, got: \(logs.all)")
        XCTAssertTrue(report.first?.contains("1 sub was") ?? false, "must say how many: \(report)")
        XCTAssertTrue(report.first?.contains("did not delete the original files") ?? false,
                      "wording must claim only what this session controls: \(report)")

        let summary = (try? String(contentsOf: base.appendingPathComponent("session-summary.md"), encoding: .utf8)) ?? ""
        XCTAssertTrue(summary.contains("Detected but not processed before the session ended"),
                      "persisted, not merely logged:\n\(summary)")
        XCTAssertTrue(summary.contains("this session did not delete the original files"), summary)

        let final = source.intakeSnapshot
        XCTAssertEqual(final.unprocessedAtShutdown, 1)
        XCTAssertEqual(final.readFailures, 0)
        XCTAssertTrue(final.accountingComplete, "the relay must have been allowed to finish")

        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: subs.path))?
            .filter { $0.hasSuffix(".fit") }.sorted() ?? []
        XCTAssertEqual(onDisk, ["Light_001.fit", "Light_002.fit", "Light_003.fit"],
                       "this session must not have deleted anything")
    }

    /// The third category: subs the operator deliberately skipped at Start. Reported
    /// separately from "not processed" — a choice is not a shortfall.
    func testExcludedPreExistingSubsAreReportedAsAChoiceNotAShortfall() throws {
        try assertExcludedSubsReported(replaceIdentically: false)
    }

    func testIdenticalReplacementExclusionsReachManifestAndSummary() throws {
        try assertExcludedSubsReported(replaceIdentically: true)
    }

    private func assertExcludedSubsReported(replaceIdentically: Bool) throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeSub(subs, "Light_001.fit", dx: 0)
        try writeSub(subs, "Light_002.fit", dx: 1.5)
        try writeSub(subs, "Light_003.fit", dx: 3.0)

        var snapshot = try WatchFolderInput.snapshot(folder: subs, fileNamePrefix: "Light_")
        if replaceIdentically {
            snapshot = try snapshot.addingContentBaseline()
            for name in snapshot.existing.keys {
                let url = subs.appendingPathComponent(name)
                try Data(contentsOf: url).write(to: url, options: .atomic)
            }
        }
        let source = FolderFrameSource(folder: subs, mode: .live, fileNamePrefix: "Light_",
                                       excludingPreExisting: snapshot)
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "Excluded", telescope: "T", camera: "C",
                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                subExposureSeconds: 180, notes: ""),
            rootDirectory: sessions)
        let logs = Box()
        pipeline.onLog = { logs.add($0) }
        try pipeline.start()

        // Wait for the source to have accounted for all three exclusions, then end.
        let deadline = Date().addingTimeInterval(20)
        while source.intakeSnapshot.excludedPreExisting < 3 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 3, "precondition: all three skipped")
        let dir = try pipeline.end()

        let base = dir.hasDirectoryPath ? dir : dir.deletingLastPathComponent()
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.sourceExcludedPreExistingCount, 3)
        XCTAssertEqual(manifest.sourceUnprocessedAtShutdownCount, 0)
        XCTAssertEqual(manifest.sourceAccountingComplete, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: subs.path).filter { $0.hasSuffix(".fit") }.count, 3)
        let summary = (try? String(contentsOf: base.appendingPathComponent("session-summary.md"), encoding: .utf8)) ?? ""
        XCTAssertTrue(summary.contains("Pre-existing subs skipped by choice | 3"),
                      "the summary must record the choice:\n\(summary)")
        XCTAssertFalse(summary.contains("Detected but not processed"),
                       "a deliberate skip is NOT an unprocessed shortfall:\n\(summary)")
        XCTAssertTrue(logs.all.contains { $0.contains("skipped by choice at Start") },
                      "logs: \(logs.all)")
    }

    /// Finding 2. A sub pulled but unreadable — deleted after the watcher validated it,
    /// before the consumer pulled — is neither a processed frame nor a sub left unprocessed
    /// at shutdown. It is its own category and must not hide inside either other one.
    ///
    /// (An UNDECODABLE file is not the path to test: the watcher classifies it `.invalid`
    /// and never emits it, so it never reaches the pull at all.)
    func testUnreadableSubIsCountedAsAReadFailureNotAsProcessed() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSub(dir, "Light_a.fit", dx: 0)
        try writeSub(dir, "Light_b.fit", dx: 1.5)

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        defer { source.stop() }
        let buffered = expectation(description: "both updates buffered")
        buffered.expectedFulfillmentCount = 2
        let order = Box()
        source.liveSeams.onUpdateBuffered = { order.add($0.url.lastPathComponent); buffered.fulfill() }
        try source.start()
        await fulfillment(of: [buffered], timeout: 20)

        // Same-poll buffer order is not deterministic, so drop whichever landed first.
        let dropped = try XCTUnwrap(order.all.first)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(dropped))

        var it = source.frames.makeAsyncIterator()
        let got = await it.next()
        XCTAssertNotNil(got, "the surviving sub is still delivered")

        let intake = source.intakeSnapshot
        XCTAssertEqual(intake.admitted, 2)
        XCTAssertEqual(intake.readFailures, 1, "the vanished sub must be its own category")
        XCTAssertEqual(intake.delivered, 1, "only the survivor reached the stacker")
        XCTAssertEqual(intake.unprocessedAtShutdown, 0,
                       "a read failure must NOT be laundered into the unprocessed remainder")
    }

    /// Finding 1, made decisive. The relay is PARKED mid-batch (inside the admission seam)
    /// when stop() lands. A stop() that cancels the relay there loses every admission still
    /// to come and publishes the partial tallies as final; a stop() that waits lets the relay
    /// finish, so the counts describe the whole batch.
    ///
    /// This is the test that distinguishes them — an unparked relay finishes too fast to tell.
    func testStopWaitsForTheRelaySoLateAdmissionsAreNotLost() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let total = 12
        for i in 1...total { try writeSub(dir, String(format: "Light_%03d.fit", i), dx: Double(i % 3)) }

        // No consumer: updates reach the relay but remain undecoded. Exclusions now
        // bypass the relay, so they cannot exercise its shutdown barrier.
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let parkedOnce = UncheckedBox(false)
        source.liveSeams.onUpdateAdmitted = { _ in
            if !parkedOnce.value {
                parkedOnce.value = true
                parked.signal()
                _ = release.wait(timeout: .now() + 60)   // hold the relay mid-batch
            }
        }
        try source.start()
        XCTAssertEqual(parked.wait(timeout: .now() + 30), .success, "relay must reach admission")
        // Let the WATCHER emit the whole batch into the relay's stream while the relay is
        // parked. Those updates are now in hand and uncounted — precisely the state in which
        // cancelling the relay would lose them. (Several poll cycles at the 2 s default.)
        Thread.sleep(forTimeInterval: 7)
        XCTAssertEqual(source.intakeSnapshot.admitted, 1,
                       "precondition: the relay is parked on the first update, the rest queued")

        // stop() on another thread, so we can release the park while it is waiting.
        let stopped = expectation(description: "stop() returned")
        DispatchQueue.global().async { source.stop(timeout: 10); stopped.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)   // let stop() reach the barrier
        release.signal()
        wait(for: [stopped], timeout: 30)

        let intake = source.intakeSnapshot
        XCTAssertTrue(intake.accountingComplete,
                      "stop() must wait for the relay, not cancel it mid-admission")
        XCTAssertEqual(intake.admitted, total,
                       "every update the watcher produced must be admitted before counts are final")
        XCTAssertEqual(intake.excludedPreExisting, 0)
        XCTAssertEqual(intake.unprocessedAtShutdown, total)
    }

    /// Parks the relay mid-batch so a stop() must contend with an unfinished relay, then
    /// stops with `budget` and reports how long stop() actually took.
    private func stopWithParkedRelay(budget: TimeInterval, releaseAfter: TimeInterval,
                                     fileCount: Int = 8)
        throws -> (elapsed: TimeInterval, intakeAtStop: SourceIntake, intakeLater: SourceIntake) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...fileCount { try writeSub(dir, String(format: "Light_%03d.fit", i), dx: Double(i % 3)) }

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let parkedOnce = UncheckedBox(false)
        source.liveSeams.onUpdateAdmitted = { _ in
            if !parkedOnce.value {
                parkedOnce.value = true
                parked.signal()
                _ = release.wait(timeout: .now() + 60)
            }
        }
        try source.start()
        XCTAssertEqual(parked.wait(timeout: .now() + 30), .success, "relay must park")
        Thread.sleep(forTimeInterval: 5)   // let the watcher queue the rest behind the park

        // Release on a timer so the relay finishes LATE — after stop()'s budget has expired.
        DispatchQueue.global().asyncAfter(deadline: .now() + releaseAfter) { release.signal() }
        let t0 = Date()
        source.stop(timeout: budget)
        let elapsed = Date().timeIntervalSince(t0)
        let atStop = source.intakeSnapshot
        Thread.sleep(forTimeInterval: releaseAfter + 1.0)   // give the late relay time to finish
        return (elapsed, atStop, source.intakeSnapshot)
    }

    /// An exhausted budget grants no fresh allowance to either step, and a relay that
    /// completes LATE must not retroactively make the accounting look complete.
    func testExhaustedBudgetGrantsNoFreshAllowanceAndStaysIncomplete() throws {
        let r = try stopWithParkedRelay(budget: 0, releaseAfter: 2.0)
        // Tight on purpose: the retired 500 ms floor would land here at ~0.5 s, and a floor
        // IS a fresh allowance to a caller that allowed none.
        XCTAssertLessThan(r.elapsed, 0.35,
                          "a zero budget must not buy a fresh allowance per step; took \(r.elapsed)s")
        XCTAssertFalse(r.intakeAtStop.accountingComplete,
                       "the relay never finished inside the budget — say so")
        XCTAssertFalse(r.intakeLater.accountingComplete,
                       "a LATE relay completion must not flip the accounting back to complete")
    }

    /// A caller asking for less than half a second gets less than half a second. The old
    /// `max(timeout, 0.5)` floor handed such a caller MORE time than it allowed.
    func testSubHalfSecondBudgetIsHonouredNotFloored() throws {
        let r = try stopWithParkedRelay(budget: 0.2, releaseAfter: 3.0)
        XCTAssertLessThan(r.elapsed, 0.5,
                          "a 0.2s budget must not be floored up to 0.5s; took \(r.elapsed)s")
        XCTAssertFalse(r.intakeAtStop.accountingComplete)
        XCTAssertFalse(r.intakeLater.accountingComplete,
                       "late completion cannot un-mark incomplete accounting")
    }
}
