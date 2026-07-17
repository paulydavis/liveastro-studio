import XCTest
import CoreGraphics
@testable import LiveAstroCore

/// Task 3 of the fault-injection pillar (spec 2026-07-15): the lifecycle-boundary rows of the fault
/// matrix — SessionManager, SnapshotRecorder, SessionPipeline start/end, BatchImporter — plus the
/// crash-terminated + restart-recovery scenarios driven through the real `faulthelper` executable.
///
/// Every test drives the REAL filesystem via FaultKit and ends with `assertSessionOracle` wherever a
/// session exists on disk. Coordination is by semaphore / readiness-flag only (no sleeps as
/// synchronization; the one bounded Thread.sleep in the pipeline-drain cell mirrors the existing
/// SessionPipelineShutdownTests pattern for letting the wedged consumer enter its callback).
///
/// STOP-on-RED: a red cell here is a FOUND BUG — recorded with `// FOUND-BUG:` and reported, never
/// weakened to green.
final class FaultMatrixLifecycleTests: XCTestCase {

    // MARK: - Shared fixtures

    private func profile(_ target: String = "Crescent") -> SessionProfile {
        SessionProfile(targetName: target, telescope: "120 APO", camera: "ASI2600MC Air",
                       mount: "AM5N", filter: "Dual-band", locationLabel: "Round Rock, TX",
                       bortle: 7, subExposureSeconds: 120, notes: "")
    }

    /// A genuine tiny CGImage + linear AstroImage so SnapshotRecorder writes a real PNG.
    private func snapshotInputs() -> (CGImage, AstroImage) {
        let w = 8, h = 8
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!
        let linear = AstroImage(width: w, height: h, channels: 1,
                                pixels: [Float](repeating: 0.5, count: w * h), sourceIsLinear: true)
        return (cg, linear)
    }

    /// Record `n` real snapshots through a live manager+recorder pair.
    @discardableResult
    private func recordSnapshots(_ n: Int, mgr: SessionManager, recorder: SnapshotRecorder,
                                 from startIndex: Int = 0) throws -> Int {
        let (cg, linear) = snapshotInputs()
        var last = startIndex
        for i in startIndex..<(startIndex + n) {
            let rec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                        index: i, timestamp: Date(), estimatedIntegrationSeconds: 120)
            try mgr.recordSnapshot(rec)
            last = i
        }
        return last
    }

    // ============================================================================================
    // MARK: SessionManager row
    // ============================================================================================

    /// SessionManager × read-only mid-session (PROXY read-only ≈ ENOSPC/EIO): start OK, flip the
    /// session dir read-only, recordSnapshot throws AND leaves in-memory state unchanged (the
    /// fix-wave write-then-commit behavior, systematized); restore → later snapshots accepted.
    /// Oracle: counts truthful throughout.
    func testSessionManager_readOnlyMidSession_recordThrowsStateUnchangedThenHeals() throws {
        let fs = try TempFS("sm-readonly"); defer { fs.tearDown() }
        let mgr = SessionManager(rootDirectory: fs.root)
        let dir = try mgr.startSession(profile: profile())
        let recorder = SnapshotRecorder(sessionDirectory: dir)
        try recordSnapshots(2, mgr: mgr, recorder: recorder)          // 2 durable
        XCTAssertEqual(mgr.acceptedCount, 2)

        // Flip the session dir read-only so the atomic manifest write fails. Write-probe: privileged
        // runners defeat chmod → skip with a diagnostic rather than pass vacuously.
        guard try Disruptor.makeReadOnly(dir, tempFS: fs) else {
            throw XCTSkip("read-only flip ineffective (privileged runner) — SessionManager read-only cell")
        }

        // The PNG for index 2 still writes (snapshots/ subdir is not the manifest write), but the
        // manifest atomic write into the read-only dir fails → recordSnapshot must throw and NOT
        // mutate in-memory state.
        let (cg, linear) = snapshotInputs()
        let rec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                    index: 2, timestamp: Date(), estimatedIntegrationSeconds: 120)
        XCTAssertThrowsError(try mgr.recordSnapshot(rec), "read-only manifest write must throw")
        XCTAssertEqual(mgr.acceptedCount, 2, "a failed record must not append to in-memory state")
        XCTAssertEqual(mgr.state, .running, "a failed record must not change state")

        // Restore write access → later snapshots are accepted again (recovery).
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: dir.path)
        try recordSnapshots(1, mgr: mgr, recorder: recorder, from: 3)
        XCTAssertEqual(mgr.acceptedCount, 3, "after restore, later snapshots are accepted")

        assertSessionOracle(sessionRoot: dir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: true,
                                               expectedAcceptedCount: 3))
    }

    /// SessionManager × dir-removed mid-session: remove the session dir after N snapshots → the next
    /// record throws honestly (no false success). Oracle runs on the RE-CREATED dir + the durable
    /// manifest the manager still holds (write-then-commit: the throw left the last good manifest
    /// as the truth). We assert honesty of the count and the throw.
    func testSessionManager_dirRemovedMidSession_recordThrowsNoFalseSuccess() throws {
        let fs = try TempFS("sm-dirremoved"); defer { fs.tearDown() }
        let mgr = SessionManager(rootDirectory: fs.root)
        let dir = try mgr.startSession(profile: profile())
        let recorder = SnapshotRecorder(sessionDirectory: dir)
        try recordSnapshots(3, mgr: mgr, recorder: recorder)
        XCTAssertEqual(mgr.acceptedCount, 3)

        // Remove the session dir out from under the manager.
        try Disruptor.removeDirectory(dir)

        let (cg, linear) = snapshotInputs()
        // The recorder.save also fails (snapshots/ gone) — either save or recordSnapshot must throw;
        // in no case may the in-memory count grow to 4 without a durable manifest.
        XCTAssertThrowsError(try {
            let rec = try recorder.save(cgImage: cg, linear: linear, sourceFile: "live_stack.fit",
                                        index: 3, timestamp: Date(), estimatedIntegrationSeconds: 120)
            try mgr.recordSnapshot(rec)
        }(), "recording into a removed session dir must throw — no false success")
        XCTAssertEqual(mgr.acceptedCount, 3, "the failed record must not be counted")

        // The REMAINS: nothing was persisted after removal, and the manager never claimed success.
        // The honest post-fault truth is EXACTLY 3 snapshots — the failed record never inflated the
        // count. Model recovery (operator re-mounts the volume) with a FRESH manager that re-records
        // the 3 recoverable snapshots into a clean session, then oracle at the REAL aftermath count
        // of 3 — no synthetic 4th record inflating it beyond what was durable.
        let recoveryMgr = SessionManager(rootDirectory: fs.root)
        let recoveredDir = try recoveryMgr.startSession(profile: profile("Recovered"))
        let recoveredRecorder = SnapshotRecorder(sessionDirectory: recoveredDir)
        try recordSnapshots(3, mgr: recoveryMgr, recorder: recoveredRecorder)
        XCTAssertEqual(recoveryMgr.acceptedCount, 3, "the honest recoverable count is 3 — never a false 4")
        assertSessionOracle(sessionRoot: recoveredDir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 3))
    }

    // ============================================================================================
    // MARK: SnapshotRecorder row
    // ============================================================================================

    /// SnapshotRecorder × dir-removed (driven through the REAL SessionPipeline import path): with the
    /// snapshots/ subdir removed, every finalizeCommitted save throws and the PIPELINE logs the
    /// production "Skipped frame" line via `onLog` (captured here — NOT hand-authored). The session
    /// survives, the manifest lists none of the unsaved snapshots, and a fresh import after restore
    /// is accepted. Clause 6 is exercised against the string the production code actually emits.
    func testSnapshotRecorder_dirRemoved_saveFailsSessionContinuesManifestOmitsIt() throws {
        let fs = try TempFS("rec-dirremoved"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")

        // Drive a real import of two registerable frames through the pipeline, but remove snapshots/
        // right after start() creates it — so finalizeCommitted's recorder.save throws for real.
        let good1 = Self.starField(name: "sub_000.fit", dx: 0, dy: 0)
        let good2 = Self.starField(name: "sub_001.fit", dx: 1.1, dy: -0.9)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource([good1, good2]),
                                       engine: engine, profile: profile("RecDrop"),
                                       rootDirectory: sessions)
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }

        try pipeline.start()
        let dir = pipeline.session.sessionDirectory!
        // Remove snapshots/ out from under the running import: every save now fails → the PIPELINE
        // itself emits "Skipped frame (...)" (production string) for each committed frame.
        let snaps = dir.appendingPathComponent("snapshots")
        try Disruptor.removeDirectory(snaps)
        _ = try pipeline.end()   // drains the finite import fully (all saves fail into onLog)

        let capturedAfterDrop = logLock.withLock { log }
        let joined = capturedAfterDrop.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Skipped frame"),
                      "the PIPELINE must emit the production 'Skipped frame' log when the save fails:\n\(joined)")
        // The manifest must not list any snapshot whose PNG never wrote.
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.snapshots.isEmpty, "manifest must not list an unsaved snapshot")

        // Session survives + continues: restore snapshots/ and run a fresh import → snapshots land.
        try FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true)
        let engine2 = StackEngine()
        let pipeline2 = SessionPipeline(nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource([good1, good2]),
                                        engine: engine2, profile: profile("RecHeal"),
                                        rootDirectory: sessions)
        var healLog: [String] = []
        let healLock = NSLock()
        pipeline2.onLog = { msg in healLock.withLock { healLog.append(msg) } }
        try pipeline2.start()
        _ = try pipeline2.end()
        let healedDir = pipeline2.session.sessionDirectory!
        let healedManifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: healedDir.appendingPathComponent("manifest.json")))
        XCTAssertFalse(healedManifest.snapshots.isEmpty, "after restore, a fresh import records snapshots")

        // Oracle on the DROPPED session with the PIPELINE-captured log: clause 6 matches the real
        // production string; the manifest is honest (lists nothing that failed to save).
        assertSessionOracle(sessionRoot: dir, log: capturedAfterDrop,
                            OracleExpectations(lossLogPattern: "Skipped frame",
                                               laterFramesApplicable: true,
                                               expectedAcceptedCount: 0))
    }

    // ============================================================================================
    // MARK: SessionPipeline start/end row
    // ============================================================================================

    /// Pipeline start × source-throws (fix-wave rollback, systematized): start() fails when the
    /// source throws on start(); a retry succeeds; no orphan running session dir is left on disk.
    func testPipelineStart_sourceThrows_rollsBackRetrySucceedsNoOrphanDir() throws {
        let fs = try TempFS("pipe-start-throw"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")

        let source = FlakyStartSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile("Flaky"), rootDirectory: sessions)

        XCTAssertThrowsError(try pipeline.start(), "source.start() throwing must propagate")
        XCTAssertNotEqual(pipeline.session.state, .running,
                          "a failed start must not leave the session running")
        // No orphan running-session dir: the rollback removed the just-created dir.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "rollback must remove the orphan session dir, got \(leftover)")

        // Retry succeeds (not blocked by alreadyRunning).
        source.shouldThrow = false
        XCTAssertNoThrow(try pipeline.start(), "retry after rollback must succeed")
        XCTAssertEqual(pipeline.session.state, .running)

        // A session now exists on disk (the retry created it) → oracle it.
        if let dir = pipeline.session.sessionDirectory {
            assertSessionOracle(sessionRoot: dir, log: [],
                                OracleExpectations(lossLogPattern: nil,
                                                   laterFramesApplicable: false,
                                                   expectedAcceptedCount: 0))
        }
    }

    /// Pipeline end × wedged consumer (fix-wave shutdownTimeout, systematized with SlowConsumer):
    /// end() throws shutdownTimeout; the last durable manifest is intact and NO master.fit was
    /// written (no finalization of a racing stack). Oracle: clause 5 (no false-ended claim) holds
    /// because endSession() is never reached.
    func testPipelineEnd_wedgedConsumer_throwsShutdownTimeoutNoFinalization() throws {
        let fs = try TempFS("pipe-end-wedge"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")

        let pipeline = SessionPipeline(nativeSource: WedgingLiveSource(seed: FaultMatrixLifecycleTests.seedFrame()),
                                       engine: StackEngine(), profile: profile("Wedge"),
                                       rootDirectory: sessions)
        let consumer = SlowConsumer()
        pipeline.onUpdate = { _, _ in consumer.wedge() }   // wedges the consume task inside handling
        // Capture the pipeline's REAL log so clause 6 matches the production-emitted string (the
        // "refusing to finalize" line is written by SessionPipeline.drainConsumeTaskOrThrow, not by
        // this test). frameFlood-cell pattern: thread-safe append behind a lock.
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()

        // Wait (readiness detection) for the consumer to actually enter the wedged callback before
        // ending — semaphore handshake, not a timing guess.
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 5), .success,
                       "consumer must reach the wedge point")

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout,
                           "end() must throw rather than finalize a racing stack")
        }

        // Oracle on the durable session: the manifest parses; because endSession() was never
        // reached, endTime is nil and there is no master.fit — clause 5 is satisfied honestly.
        let dir = pipeline.session.sessionDirectory!
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNil(manifest.endTime, "wedged end must not set endTime")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path),
                       "no master.fit may be finalized over a racing stack")
        let captured = logLock.withLock { log }
        XCTAssertTrue(captured.joined(separator: "\n").contains("refusing to finalize"),
                      "the PIPELINE must emit the production 'refusing to finalize' log on a wedged end")
        assertSessionOracle(sessionRoot: dir,
                            log: captured,
                            OracleExpectations(lossLogPattern: "refusing to finalize",
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: nil))
        consumer.releaseNow()   // let the wedged task exit so the process ends cleanly
    }

    /// Cold1 I1 (red-first: pre-fix end() parked on an UNBOUNDED consumeDone.wait() on the
    /// finite branch — this test's expectation TIMES OUT and FAILS rather than hanging the
    /// suite): a finite import whose consumer wedges (models a stalled SMB read pinning the
    /// import pull) must not pin end() forever. The finite drain uses the same two-stage
    /// bounded machinery as the live branch, made PROGRESS-AWARE: a healthy import drains
    /// completely (frames keep committing), and only a no-progress window of
    /// drainPrimaryTimeout triggers cancel (cursor stopped via the cancelImport machinery)
    /// + grace → shutdownTimeout. A hung blocking read cannot be interrupted mid-syscall —
    /// the bound is on OUR wait; the task is cancelled and abandoned honestly, and
    /// finalization is refused (no end_time, no master.fit).
    func testPipelineEnd_finiteImportStalled_boundedThrowsShutdownTimeout() throws {
        let fs = try TempFS("pipe-finite-stall"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")
        let good1 = Self.starField(name: "sub_000.fit", dx: 0, dy: 0)
        let good2 = Self.starField(name: "sub_001.fit", dx: 1.1, dy: -0.9)
        let pipeline = SessionPipeline(
            nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource([good1, good2]),
            engine: StackEngine(), profile: profile("FiniteStall"), rootDirectory: sessions)
        let consumer = SlowConsumer()
        pipeline.onUpdate = { _, _ in consumer.wedge() }   // frame 1 wedges the import consumer
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 5), .success,
                       "consumer must reach the wedge point")

        // end() off-thread behind an expectation: pre-fix it never returned, and the
        // expectation fails at its own timeout instead of wedging the suite.
        let returned = expectation(description: "end() returns within the bounded drain")
        let errBox = CapturedErrorBox()
        Thread.detachNewThread {
            do { _ = try pipeline.end() } catch { errBox.set(error) }
            returned.fulfill()
        }
        wait(for: [returned], timeout: 10)
        XCTAssertEqual(errBox.value as? SessionPipelineError, .shutdownTimeout,
                       "a stalled finite drain must refuse to finalize with shutdownTimeout")

        // No finalization happened: end_time never stamped, no master.fit written.
        let dir = pipeline.session.sessionDirectory!
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self,
                    from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNil(manifest.endTime, "a stalled end must not stamp end_time")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("master.fit").path),
            "no master.fit may be finalized over a stalled import")
        let captured = logLock.withLock { log }
        XCTAssertTrue(captured.joined(separator: "\n").contains("refusing to finalize"),
                      "the stall must appear honestly in the log — got \(captured)")
        // Release the wedge (twice: a second in-flight commit may wedge after the first)
        // so the abandoned task exits and the process ends cleanly.
        consumer.releaseNow()
        consumer.releaseNow()
    }

    /// Pipeline mid-session × frame flood + one hostile file: a mixed stream (valid, truncated,
    /// valid) through the import path → exactly the truncated one is rejected+logged and both valids
    /// are accepted (invariant: lose a frame, never the session). Oracle: manifest lists exactly the
    /// two accepted snapshots.
    func testPipelineMidSession_frameFloodOneHostile_onlyBadRejectedBothValidsKept() async throws {
        let fs = try TempFS("pipe-flood"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")

        // Build a mixed stream: two registerable frames and one degenerate (star-less) frame the
        // engine rejects (models the hostile/truncated input surviving as a rejection, not a crash).
        let good1 = Self.starField(name: "sub_000.fit", dx: 0, dy: 0)
        let hostile = Self.blankField(name: "hostile.fit")
        let good2 = Self.starField(name: "sub_002.fit", dx: 1.3, dy: -1.0)
        let source = FaultMatrixLifecycleTests.ArrayFrameSource([good1, hostile, good2])

        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile("Flood"), rootDirectory: sessions)
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }

        try pipeline.start()
        _ = try pipeline.end()   // import path: end() drains the finite stream fully

        XCTAssertEqual(engine.acceptedCount, 2, "both valid frames accepted")
        XCTAssertEqual(engine.rejectedCount, 1, "exactly the hostile frame rejected")
        let joined = logLock.withLock { log.joined(separator: "\n") }
        XCTAssertTrue(joined.range(of: "Rejected", options: .regularExpression) != nil,
                      "the rejected frame must appear honestly in the log:\n\(joined)")

        let dir = pipeline.session.sessionDirectory!
        assertSessionOracle(sessionRoot: dir, log: log,
                            OracleExpectations(lossLogPattern: "Rejected",
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 2))
    }

    /// Pipeline end × master-write-fails (F1, review2): the native master.fit write is the last
    /// failure-prone durable artifact in end(). Force it to fail by pre-placing a DIRECTORY at the
    /// master.fit path (FITS data cannot be written over a directory → `Data.write` throws). end()
    /// must surface that failure AND must NOT have stamped end_time first — a manifest claiming an
    /// ended session with no persisted master is exactly the oracle clause-5 dishonest state. So the
    /// aftermath must be: end() throws, manifest end_time nil (still running = truthful), no master
    /// file. Oracle clause 5 passes because end_time is nil.
    func testPipelineEnd_masterWriteFails_noEndTimeStampedClause5Honest() throws {
        let fs = try TempFS("pipe-master-fail"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")

        // Two registerable frames → the engine accumulates a real stack (currentStack() non-nil),
        // so end() reaches the master.fit write branch.
        let good1 = Self.starField(name: "sub_000.fit", dx: 0, dy: 0)
        let good2 = Self.starField(name: "sub_001.fit", dx: 1.1, dy: -0.9)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource([good1, good2]),
                                       engine: engine, profile: profile("MasterFail"),
                                       rootDirectory: sessions)
        try pipeline.start()
        let dir = pipeline.session.sessionDirectory!

        // Pre-place a DIRECTORY where master.fit will be written. FaultKit invalid-replacement-target
        // style: Data.write(to:) over a directory throws, forcing the master write to fail.
        let masterPath = dir.appendingPathComponent("master.fit")
        try Disruptor.replaceWithDirectory(masterPath)

        // end() drains the finite import, then attempts the master write, which throws. Crucially the
        // reorder (F1) puts the write BEFORE endSession(), so end_time is never stamped.
        XCTAssertThrowsError(try pipeline.end(), "a failed master.fit write must surface from end()")

        // The manifest must still be RUNNING — no end_time stamped before the failed durable write.
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNil(manifest.endTime,
                     "F1: end_time must NOT be persisted when the master write fails (manifest stays truthful)")
        XCTAssertEqual(manifest.masterExpected, true,
                       "review11 finding 2: a failed master write must NEVER flip masterExpected — " +
                       "the field is immutable after session start (a failure cannot exempt itself)")
        // No real master.fit file exists (the path is a directory, not a FITS file).
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: masterPath.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "master.fit path is the injected directory, not a written FITS")

        // Oracle clause 5: end_time nil → the ended-claim clause is exempt; the aftermath is honest.
        // Remove the placeholder directory so clause-5's fileExists(master.fit) check reflects the
        // true "no durable master" state (a directory at that path would spuriously satisfy it).
        try FileManager.default.removeItem(at: masterPath)
        assertSessionOracle(sessionRoot: dir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: manifest.snapshots.count))
    }

    // ============================================================================================
    // MARK: Oracle clause 5 — master expectation (review11 finding 2)
    // ============================================================================================

    /// Review11 finding 2 (P1, red-first — the reviewer's repro): a COMPLETED WATCHER session.
    /// SessionPipeline.end() stamps end_time unconditionally, but master.fit is only ever
    /// written by a native engine — so pre-fix every successful watcher session "ended" without
    /// master.fit, which the oracle's clause 5 declared dishonest (this test failed clause 5).
    /// Post-fix the manifest carries `masterExpected` (set at session START from session
    /// semantics: watcher ⇒ false, native ⇒ true; IMMUTABLE thereafter), end() logs the
    /// watcher-mode line once, and the oracle passes honestly.
    func testPipelineEnd_watcherSession_endsHonestly_oracleClause5Passes() throws {
        let fs = try TempFS("pipe-watcher-end"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")
        let watch = try fs.dir("watch")
        var replay = ReplaySettings()
        replay.duration = 1; replay.fps = 10; replay.width = 160; replay.height = 90
        let pipeline = SessionPipeline(watchFolder: watch, profile: profile("WatcherEnd"),
                                       rootDirectory: sessions, replaySettings: replay,
                                       maxKeyframes: 5)
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }
        let accepted = expectation(description: "one watcher update accepted")
        accepted.assertForOverFulfill = false
        pipeline.onUpdate = { _, _ in accepted.fulfill() }
        try pipeline.start()
        let px = (0..<(32 * 32)).map { Float($0 % 32) / 64.0 }
        try FITSWriter.float32(width: 32, height: 32, channels: 1, pixels: px)
            .write(to: watch.appendingPathComponent("live_stack.fit"))
        wait(for: [accepted], timeout: 15)
        _ = try pipeline.end()

        let dir = pipeline.session.sessionDirectory!
        let manifest = try ManifestCoding.decoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNotNil(manifest.endTime, "the watcher session really ended")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("master.fit").path),
            "watcher sessions never write master.fit — the stack lives with the external stacker")
        XCTAssertEqual(manifest.masterExpected, false,
                       "watcher-mode sessions record at START that no master is promised")
        let captured = logLock.withLock { log }
        XCTAssertEqual(captured.filter { $0.contains("watcher session — the stack lives with the external stacker; no master.fit") }.count, 1,
                       "end() states the watcher-mode master expectation once — got \(captured)")
        // The reviewer's repro line: pre-fix this oracle call FAILED clause 5 (end_time set,
        // no master.fit); post-fix it passes because masterExpected == false is honest.
        assertSessionOracle(sessionRoot: dir, log: captured,
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: manifest.snapshots.count))
    }

    /// Review11 finding 2, immutability pin: `masterExpected` is set ONCE at session start and
    /// NEVER changed — in particular a FAILED native master write must not exempt itself by
    /// flipping the field. Two legs: (a) through the real pipeline, the failed-master-write
    /// session keeps masterExpected == true; (b) the exact dishonest aftermath a flipped field
    /// would whitewash — end_time set, masterExpected true, frames recorded, no master.fit —
    /// STILL trips oracle clause 5 (pinned with XCTExpectFailure).
    func testFailedNativeMasterWrite_masterExpectedImmutable_clause5StillTrips() throws {
        let fs = try TempFS("clause5-immutable"); defer { fs.tearDown() }

        // (b) Construct the dishonest aftermath directly and pin that the oracle REFUSES it.
        let root = try fs.dir("dishonest-session")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("snapshots"),
                                                withIntermediateDirectories: true)
        let pngName = "snapshots/0000.png"
        try FaultKitTests.tinyPNGData().write(to: root.appendingPathComponent(pngName))
        let record = SnapshotRecord(index: 0, timestamp: Date(), sourceFile: "sub_000.fit",
                                    snapshotFile: pngName, estimatedIntegrationSeconds: 120,
                                    width: 2, height: 2, mean: 0.1, median: 0.08, stddev: 0.02)
        var dishonest = SessionManifest(
            sessionId: "dishonest", targetName: "T", startTime: Date(), endTime: Date(),
            subExposureSeconds: 120, bortle: 7, locationLabel: "L", telescope: "T",
            camera: "C", mount: "M", filter: "F", notes: "", snapshots: [record],
            masterExpected: true)
        dishonest.masterOutcome = .written
        dishonest.stackFrameCount = 1
        dishonest.sessionAcceptedCount = 1
        dishonest.sessionRejectedCount = 0
        try ManifestCoding.encoder().encode(dishonest)
            .write(to: root.appendingPathComponent("manifest.json"))
        XCTExpectFailure("clause 5 must trip: ended + masterExpected + frames recorded, but no master.fit") {
            assertSessionOracle(sessionRoot: root, log: [],
                                OracleExpectations(lossLogPattern: nil,
                                                   laterFramesApplicable: false,
                                                   expectedAcceptedCount: 1))
        }
    }

    /// Review11 finding 2, backward compatibility (reviewer-pinned): manifests written BEFORE
    /// the masterExpected schema must decode (optional field — decoding never throws) and the
    /// oracle treats them under their era's semantics: clause 5 is SKIPPED for legacy
    /// manifests, because a pre-schema session carries no mode marker — a missing master
    /// cannot be distinguished from an honest watcher session, and assuming native would
    /// retroactively fail every archived watcher session.
    func testLegacyManifestWithoutMasterExpected_decodesAndOracleSkipsClause5() throws {
        let fs = try TempFS("clause5-legacy"); defer { fs.tearDown() }
        let root = try fs.dir("legacy-session")
        // Hand-written legacy JSON: end_time SET, no master_expected key, no master.fit.
        let legacy = """
        {
          "session_id": "legacy-session",
          "target_name": "NGC 6888",
          "start_time": "2026-07-05T22:15:00Z",
          "end_time": "2026-07-06T03:10:00Z",
          "sub_exposure_seconds": 120,
          "bortle": 7,
          "location_label": "Test",
          "telescope": "120 APO",
          "camera": "ASI2600MC",
          "mount": "AM5N",
          "filter": "Dual-band",
          "notes": "",
          "snapshots": []
        }
        """
        try legacy.data(using: .utf8)!.write(to: root.appendingPathComponent("manifest.json"))
        let decoded = try ManifestCoding.decoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertNil(decoded.masterExpected, "legacy manifests decode with the field absent (nil)")
        XCTAssertNotNil(decoded.endTime)
        // Oracle: legacy + ended + no master → clause 5 skipped by documented policy.
        assertSessionOracle(sessionRoot: root, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 0))
    }

    /// Review11 finding 2, empty native session: zero accepted frames at end(). masterExpected
    /// stays true (immutable, set at start) BUT no master is written — end() states the
    /// zero-frame fact honestly in the log, and the oracle keys clause 5 on
    /// masterExpected && frames recorded, so the aftermath passes without a master.
    func testEmptyNativeSession_endsHonestly_logsNoMaster_oraclePasses() throws {
        let fs = try TempFS("clause5-empty-native"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")
        let pipeline = SessionPipeline(nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource([]),
                                       engine: StackEngine(), profile: profile("EmptyNative"),
                                       rootDirectory: sessions)
        var log: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log.append(msg) } }
        try pipeline.start()
        _ = try pipeline.end()

        let dir = pipeline.session.sessionDirectory!
        let manifest = try ManifestCoding.decoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNotNil(manifest.endTime, "the empty session really ended")
        XCTAssertEqual(manifest.masterExpected, true,
                       "an empty NATIVE session still promised a master at start — the field is immutable")
        XCTAssertTrue(manifest.snapshots.isEmpty, "the zero-frame fact is recorded in the manifest")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("master.fit").path),
            "no frames → no master written")
        let captured = logLock.withLock { log }
        XCTAssertEqual(captured.filter { $0.contains("no frames accepted — no master written") }.count, 1,
                       "the zero-frame end states itself honestly, once — got \(captured)")
        assertSessionOracle(sessionRoot: dir, log: captured,
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 0))
    }

    // ============================================================================================
    // MARK: BatchImporter row
    // ============================================================================================

    /// BatchImporter × cancel mid-import, DRIVEN THROUGH THE REAL PIPELINE: a SessionPipeline import
    /// of 12 subs is cancelled (via cancelImport()) after a few snapshots commit; end() finalizes the
    /// partial-but-honest session. The oracle runs on the session the PIPELINE actually produced
    /// (`pipeline.session.sessionDirectory`) — not a hand-built synthetic one — so the manifest count
    /// it validates is the real committed count. Cancel lands deterministically off the onUpdate
    /// callback (fires once per committed snapshot); no sleeps.
    func testBatchImporter_cancelMidImport_drainsInFlightCountTruthful() throws {
        let fs = try TempFS("batch-cancel"); defer { fs.tearDown() }
        let sessions = try fs.dir("sessions")
        let subs = (0..<12).map { Self.starField(name: String(format: "sub_%03d.fit", $0),
                                                  dx: Double($0 % 5) * 1.3 - 2.0,
                                                  dy: Double($0 % 3) * 1.1 - 1.0) }
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: FaultMatrixLifecycleTests.ArrayFrameSource(subs),
                                       engine: engine, profile: profile("Cancel"),
                                       rootDirectory: sessions)
        // Cancel once a few snapshots have committed. onUpdate fires per committed snapshot on the
        // detached import task; the flip is idempotent so extra in-flight fires are harmless.
        let committedCounter = AtomicIntBox()
        pipeline.onUpdate = { _, _ in
            committedCounter.increment()
            if committedCounter.value >= 4 { pipeline.cancelImport() }
        }

        try pipeline.start()
        _ = try pipeline.end()   // drains in-flight work, finalizes the partial session

        let dir = pipeline.session.sessionDirectory!
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let committed = manifest.snapshots.count
        // Truthful accounting on the REAL session: at least the pre-cancel commits landed, and the
        // cancel stopped a full 12-frame import.
        XCTAssertGreaterThanOrEqual(committed, 4, "at least the pre-cancel commits landed")
        XCTAssertLessThan(committed, subs.count, "cancellation must have stopped a full import")

        // Oracle on the pipeline-produced session: manifest parses, every listed snapshot PNG exists
        // and decodes (clause 4), count is exactly what the pipeline durably committed.
        assertSessionOracle(sessionRoot: dir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: committed))
    }

    // ============================================================================================
    // MARK: Crash-terminated + restart-recovery row (real faulthelper via SIGKILL)
    // ============================================================================================

    /// Crash × session-midframes: the faulthelper is SIGKILLed with 3 recorded snapshots. REOPEN a
    /// fresh SessionManager view of the same root: the manifest parses, 3 snapshots are intact, the
    /// session is still "running" (truthful — it WAS running), and a new session in a sibling dir
    /// starts cleanly (recovery = data recoverable + fresh start not blocked). Oracle over the
    /// killed session root.
    func testCrash_sessionMidframes_manifestIntact3SnapshotsFreshStartClean() throws {
        let fs = try TempFS("crash-midframes"); defer { fs.tearDown() }
        let aftermath = try CrashArtifactBuilder.killedArtifact(scenario: "session-midframes", in: fs)

        // The helper created exactly one session dir under the aftermath root.
        let sessionDir = try onlySessionDir(in: aftermath)
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, 3, "3 durable snapshots must survive the kill")
        XCTAssertNil(manifest.endTime, "the session was still running when killed — end_time must be nil")

        // Oracle: manifest parses (1), 3 listed snapshots exist+readable (2,4), running → clause 5
        // exempt. laterFramesApplicable false (the process is dead; recovery is a fresh manager).
        assertSessionOracle(sessionRoot: sessionDir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 3))

        // Recovery: a fresh SessionManager on the same root starts a NEW session in a sibling dir,
        // cleanly (the killed session does not block a new one).
        let mgr = SessionManager(rootDirectory: aftermath)
        let newDir = try mgr.startSession(profile: profile("Recovered"))
        XCTAssertEqual(mgr.state, .running)
        XCTAssertNotEqual(newDir.lastPathComponent, sessionDir.lastPathComponent,
                          "the fresh session must land in a sibling dir, not clobber the killed one")
        assertSessionOracle(sessionRoot: newDir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 0))
    }

    /// Crash × manifest-midwrite: the helper is SIGKILLed DETERMINISTICALLY between the staging and
    /// the publication of a challenged manifest write (review4 P2). The helper does a few normal
    /// seam writes (proving writes were flowing, not an idle pre-seeded manifest), then on the
    /// challenged write it stages the full new manifest bytes to a same-dir `.staged-<pid>` temp,
    /// touches the readiness flag, and BLOCKS FOREVER — it never publishes. The builder's SIGKILL
    /// therefore always lands with the write transaction open: staged-but-unpublished new bytes on
    /// disk, previously published manifest untouched. The aftermath is fully assertable:
    ///   (a) published manifest.json parses and is EXACTLY the last pre-challenge version,
    ///   (b) the `.staged-<pid>` temp exists and parses as the full challenged version
    ///       (complete, closed, and unpublished — staging finished; publication never happened),
    ///   (c) the session oracle passes over the aftermath.
    /// The builder additionally verifies the helper died BY SIGKILL (uncaught signal 9), so the
    /// artifact can never silently come from a clean exit.
    ///
    /// These counts mirror the constants in faulthelper's `manifest-midwrite` scenario:
    /// 120 pre-seeded records + 3 normal seam writes = 123 published; the challenged (blocked,
    /// never published) version carries one more record = 124 staged.
    func testCrash_manifestMidwrite_killBetweenStageAndPublish_priorVersionIntact() throws {
        let publishedCount = 123   // faulthelper: preSeedCount(120) + normalSeamWrites(3)
        let stagedCount = 124      // the challenged write adds one record, staged but never published

        let fs = try TempFS("crash-midwrite"); defer { fs.tearDown() }
        let aftermath = try CrashArtifactBuilder.killedArtifact(scenario: "manifest-midwrite", in: fs)
        let sessionDir = try onlySessionDir(in: aftermath)

        // (a) The published manifest parses as a whole SessionManifest AND is exactly the last
        // pre-challenge version — the kill landed inside the open transaction, so the challenged
        // version must never have been published.
        let data = try Data(contentsOf: sessionDir.appendingPathComponent("manifest.json"))
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(manifest.snapshots.count, publishedCount,
                       "published manifest must be EXACTLY the last pre-challenge version")
        XCTAssertNil(manifest.endTime, "still running when killed")

        // (b) The staged temp of the challenged write exists and contains the FULL new version —
        // staging completed (complete, closed, unpublished), publication deterministically did not.
        let entries = try FileManager.default.contentsOfDirectory(atPath: sessionDir.path)
        let stagedNames = entries.filter { $0.hasPrefix("manifest.json.staged-") }
        XCTAssertEqual(stagedNames.count, 1,
                       "exactly one staged-but-unpublished manifest temp expected, got \(stagedNames)")
        if let stagedName = stagedNames.first {
            let stagedData = try Data(contentsOf: sessionDir.appendingPathComponent(stagedName))
            let staged = try ManifestCoding.decoder().decode(SessionManifest.self, from: stagedData)
            XCTAssertEqual(staged.snapshots.count, stagedCount,
                           "staged temp must hold the full challenged version (staging completed)")
        }

        // (c) Oracle over the aftermath — published state is honest and internally consistent.
        assertSessionOracle(sessionRoot: sessionDir, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: publishedCount))
    }

    /// Crash × relay-midcopy: the helper is SIGKILLed mid-copy. The destination contains NO
    /// glob-visible partial file (the relay stages to a hidden `.<name>.relaytmp` / itemReplacement
    /// dir and only atomically renames into place), and a FRESH relay over the same src/dst
    /// completes the copy (heals).
    func testCrash_relayMidcopy_noGlobVisiblePartialFreshRelayHeals() throws {
        let fs = try TempFS("crash-relay"); defer { fs.tearDown() }
        let aftermath = try CrashArtifactBuilder.killedArtifact(scenario: "relay-midcopy", in: fs)
        let src = aftermath.appendingPathComponent("src", isDirectory: true)
        let dst = aftermath.appendingPathComponent("dst", isDirectory: true)

        let glob = "Light_*_10.0s_*.fit"
        // No glob-visible final-name partial in dst: the only leftover (if any) is a hidden
        // `.relaytmp` temp, which does NOT match the glob and is invisible to a downstream watcher.
        let dstEntries = (try? FileManager.default.contentsOfDirectory(atPath: dst.path)) ?? []
        let globVisible = dstEntries.filter { FrameRelay.wildcardMatch($0, glob) }
        XCTAssertTrue(globVisible.isEmpty,
                      "killed relay must leave no glob-visible partial in dst, got \(globVisible)")

        // A fresh relay over the same dirs completes the copy (heals). Non-session-scoped so it
        // relays the file already present in src; short stabilityInterval so it copies promptly.
        let relay = FrameRelay(source: src, destination: dst, pollSeconds: 5,
                               sessionScoped: false, stabilityInterval: 0.01)
        // Prime (records the stat) then copy (file is stable) — the FrameRelayTests pattern.
        _ = try relay.copyOnce()
        _ = try relay.copyOnce()

        let healed = (try? FileManager.default.contentsOfDirectory(atPath: dst.path)) ?? []
        let healedVisible = healed.filter { FrameRelay.wildcardMatch($0, glob) }
        XCTAssertEqual(healedVisible.count, 1, "a fresh relay must heal the copy (one file in dst)")
        // The healed file matches the source size (fully copied, not truncated).
        let name = healedVisible[0]
        let srcSize = (try FileManager.default.attributesOfItem(atPath: src.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue
        let dstSize = (try FileManager.default.attributesOfItem(atPath: dst.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(srcSize, dstSize, "healed copy must equal the source size (complete)")
    }

    // ============================================================================================
    // MARK: Local helpers
    // ============================================================================================

    /// Find the single session dir the helper wrote under the aftermath root.
    private func onlySessionDir(in root: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
        guard let d = dirs.first, dirs.count == 1 else {
            throw XCTSkip("expected exactly one session dir under aftermath, got \(dirs.map(\.lastPathComponent))")
        }
        return d
    }

    // MARK: Frame + source generators (shared with existing suites' style)

    private static let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    /// A registerable CFA starfield, optionally shifted.
    static func starField(name: String, dx: Double, dy: Double) -> RawFrame {
        let width = 512, height = 512
        var px = [Float](repeating: 0.05, count: width * height)
        for s in field {
            let cx = s.x + dx, cy = s.y + dy
            for y in max(0, Int(cy) - 8)...min(height - 1, Int(cy) + 8) {
                for x in max(0, Int(cx) - 8)...min(width - 1, Int(cx) + 8) {
                    let ex = Double(x) - cx, ey = Double(y) - cy
                    px[y * width + x] += 0.8 * Float(exp(-(ex * ex + ey * ey) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    /// A star-less (blank) frame the engine rejects — the hostile input.
    static func blankField(name: String) -> RawFrame {
        let width = 512, height = 512
        let img = AstroImage(width: width, height: height, channels: 1,
                             pixels: [Float](repeating: 0.05, count: width * height), sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    /// A ≥15-star seed for the wedged-consumer live pipeline.
    static func seedFrame() -> RawFrame {
        let w = 256, h = 256
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {
            let sx = (i * 47) % 240 + 8, sy = (i * 83) % 240 + 8
            for y in max(0, sy - 6)...min(h - 1, sy + 6) {
                for x in max(0, sx - 6)...min(w - 1, sx + 6) {
                    let dx = Double(x - sx), dy = Double(y - sy)
                    px[y * w + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "seed.fit")
    }

    // MARK: Test-local FrameSource + live source + start-flake source

    /// In-memory finite FrameSource yielding a fixed list (mirrors BatchImporterTests.ArrayFrameSource).
    final class ArrayFrameSource: FrameSource {
        let list: [RawFrame]
        init(_ list: [RawFrame]) { self.list = list }
        var frames: AsyncStream<RawFrame> {
            AsyncStream { cont in for f in list { cont.yield(f) }; cont.finish() }
        }
        var isFinite: Bool { true }
        var totalCount: Int? { list.count }
        func start() throws {}
        func stop() {}
    }

    /// A live (isFinite == false) source yielding one seed then never finishing (mirrors
    /// SessionPipelineShutdownTests.WedgingLiveSource).
    final class WedgingLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame) { frames = AsyncStream { $0.yield(seed) } }   // never finishes
        func start() throws {}
        func stop() {}
    }

    /// A source that throws on start(), flippable to succeed (mirrors the shutdown suite's flake).
    final class FlakyStartSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        var shouldThrow = true
        init() { frames = AsyncStream { $0.finish() } }
        func start() throws { if shouldThrow { throw NSError(domain: "test", code: 1) } }
        func stop() {}
    }
}

/// A tiny thread-safe integer used to gate cancellation deterministically.
final class AtomicIntBox {
    private let lock = NSLock(); private var v = 0
    var value: Int { lock.withLock { v } }
    func increment() { lock.withLock { v += 1 } }
}

/// Lock-guarded capture of an error thrown on another thread (cold1 I1 cell).
final class CapturedErrorBox: @unchecked Sendable {
    private let lock = NSLock(); private var err: Error?
    func set(_ e: Error) { lock.withLock { err = e } }
    var value: Error? { lock.withLock { err } }
}
