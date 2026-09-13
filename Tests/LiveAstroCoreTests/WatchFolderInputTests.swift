import XCTest
@testable import LiveAstroCore

/// Red-first for the "silent about its input" fix.
///
/// A live session used to say NOTHING about the folder it was pointed at: subs already
/// present were stacked without a word, and a prefix that matched zero files looked
/// exactly like "capture hasn't started yet" (that cost a real session on 2026-09-07).
///
/// These pin the input contract the UI is built on:
///   * one shared "is this a sub" predicate — the WATCHER's, not a second guess at it;
///   * a snapshot that reports failure as failure, never as an empty folder;
///   * exclusion by IDENTITY, so a file that changed after the snapshot is still stacked.
final class WatchFolderInputTests: XCTestCase {

    func testInfiniteShutdownBudgetDoesNotTrap() {
        let source = FolderFrameSource(folder: FileManager.default.temporaryDirectory, mode: .live)
        source.stop(timeout: .infinity)
    }

    func testRunningSourceHandlesNonFiniteAndHugeShutdownBudgets() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for budget in [Double.infinity, Double.greatestFiniteMagnitude, .nan, -.infinity, -1, 0] {
            let source = FolderFrameSource(folder: dir, mode: .live)
            try source.start()
            let started = Date()
            source.stop(timeout: budget)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "empty source must stop promptly: \(budget)")
            if budget > 0 { XCTAssertTrue(source.intakeSnapshot.accountingComplete) }
            source.stop(timeout: 1) // retire any asynchronous teardown for zero budgets
        }
    }

    func testBaselineCancelsBetweenContentChunks() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_large.fit", value: 0.2, width: 4096)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        var checks = 0
        XCTAssertThrowsError(try snapshot.addingContentBaseline(shouldCancel: {
            checks += 1
            return checks >= 3 // first check is before open, second precedes the first chunk
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 3, "cancellation occurred inside the content read")
    }

    func testBaselineRejectsMutationDuringContentRead() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFITS(dir, name: "Light_large.fit", value: 0.2, width: 4096)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        var checks = 0, mutated = false
        var writeError: Error?
        XCTAssertThrowsError(try snapshot.addingContentBaseline(shouldCancel: {
            checks += 1
            if checks == 3 {
                do {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0]))
                    mutated = true
                } catch { writeError = error }
            }
            return false
        })) { XCTAssertTrue($0 is WatchFolderInput.SnapshotFailure) }
        XCTAssertNil(writeError)
        XCTAssertTrue(mutated, "fixture changed after the first chunk, not before hashing")
    }

    func testBaselineRejectsDisappearanceBetweenFiles() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_a.fit", value: 0.2)
        let second = try writeFITS(dir, name: "Light_b.fit", value: 0.3)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertThrowsError(try snapshot.addingContentBaseline(progress: { done, _ in
            if done == 1 { try? FileManager.default.removeItem(at: second) }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testEmptyPreExistingFileIsCountedAsExcluded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("Light_empty.fit"))
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_").addingContentBaseline()
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_", excludingPreExisting: snapshot)
        try source.start()
        _ = await framesDelivered(from: source, within: 3)
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 1)
    }

    func testIdenticalInvalidAndEmptyReplacementsRemainAccounted() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("Light_empty.fit")
        let invalid = dir.appendingPathComponent("Light_invalid.fit")
        try Data().write(to: empty)
        try Data("not a FITS header".utf8).write(to: invalid)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_").addingContentBaseline()
        for url in [empty, invalid] { try Data(contentsOf: url).write(to: url, options: .atomic) }
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_", excludingPreExisting: snapshot)
        try source.start()
        let delivered = await framesDelivered(from: source, within: 5)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 2)
        XCTAssertEqual(source.intakeSnapshot.admitted, 2)
        XCTAssertEqual(source.intakeSnapshot.unprocessedAtShutdown, 0)
    }

    func testBaselineIdenticalReplacementStaysExcluded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = try writeFITS(dir, name: "Light_old.fit", value: 0.2)
        let bytes = try Data(contentsOf: old)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_").addingContentBaseline()
        try bytes.write(to: old, options: .atomic)
        XCTAssertNotEqual(snapshot.existing["Light_old.fit"]?.ino, FileIdentity.capture(url: old)?.ino)
        try writeFITS(dir, name: "Light_new.fit", value: 0.3)
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_", excludingPreExisting: snapshot)
        try source.start()
        let delivered = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(delivered, ["Light_new.fit"])
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 1)
        XCTAssertEqual(try Data(contentsOf: old), bytes)
    }

    func testBaselineChangedSameSizeContentIsNotExcluded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_old.fit", value: 0.2)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_").addingContentBaseline()
        try writeFITS(dir, name: "Light_old.fit", value: 0.4)
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_", excludingPreExisting: snapshot)
        try source.start()
        let delivered = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(delivered, ["Light_old.fit"])
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 0)
    }

    func testBaselineCannotCertifyAChangedOrCancelledSnapshot() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFITS(dir, name: "Light_old.fit", value: 0.2)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertThrowsError(try snapshot.addingContentBaseline(shouldCancel: { true }))
        try Data(contentsOf: file).write(to: file, options: .atomic)
        XCTAssertThrowsError(try snapshot.addingContentBaseline())
    }

    func testExcludedFilesBypassWatcherContentReads() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_old.fit", value: 0.2)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_").addingContentBaseline()
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_", excludingPreExisting: snapshot)
        let reads = NameBox()
        source.beforeStartCommit = { watcher in watcher.beforeContentReadForTesting = { reads.append("read") } }
        try source.start()
        _ = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(reads.all.count, 0, "excluded unchanged files must not validate or hash again")
        XCTAssertEqual(source.intakeSnapshot.excludedPreExisting, 1, "early exclusion remains accounted")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFITS(_ dir: URL, name: String, value: Float, width: Int = 64) throws -> URL {
        let px = [Float](repeating: value, count: width * 32)
        let data = FITSWriter.float32(width: width, height: 32, channels: 1, pixels: px)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Collects every frame delivered within `seconds`, then stops the source. Used where the
    /// assertion is about what must NOT arrive — a blocking `for await` cannot prove absence.
    private func framesDelivered(from source: FolderFrameSource,
                                 within seconds: Double) async -> [String] {
        let box = NameBox()
        let consumer = Task { for await f in source.frames { box.append(f.sourceName) } }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        source.stop()
        _ = await consumer.value
        return box.all
    }

    private final class NameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func append(_ s: String) { lock.withLock { names.append(s) } }
        var all: [String] { lock.withLock { names } }
    }

    // MARK: - The predicate is the watcher's, not a second implementation

    /// The count shown to the operator must equal what the session actually stacks. The watcher
    /// rejects dotfiles and `.tmp` on top of prefix+extension; a preflight that only checked
    /// prefix+extension would over-report and replace silence with a wrong number.
    func testSnapshotAcceptsExactlyWhatTheWatcherStacks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)
        try writeFITS(dir, name: ".Light_hidden.fit", value: 0.2)      // dotfile: watcher skips
        try writeFITS(dir, name: "Light_partial.fit.tmp", value: 0.3)  // .tmp: watcher skips
        try writeFITS(dir, name: "Dark_001.fit", value: 0.4)           // prefix mismatch
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertEqual(Set(snapshot.existing.keys), ["Light_001.fit"],
                       "the snapshot must match the watcher's acceptance, not a laxer filter")

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        try source.start()
        let stacked = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(Set(stacked), Set(snapshot.existing.keys),
                       "what the operator is told is present must be what actually gets stacked")
    }

    /// The prefix-typo tell: files ARE present, none match. Reported as a count, so the UI can
    /// say "23 files present, none match 'Light_'" instead of an indistinguishable silence.
    func testSnapshotCountsPresentFilesThatTheFilterRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Sub_001.fit", value: 0.1)
        try writeFITS(dir, name: "Sub_002.fit", value: 0.2)

        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.unmatchedFileCount, 2,
                       "zero matches WITH files present is the prefix-typo case and must be distinguishable")
    }

    // MARK: - A failure is a failure, never "zero matches"

    /// An unreadable folder must NOT surface as "no matching subs found" — that would tell the
    /// operator to wait for files that can never arrive.
    func testSnapshotOfUnreadableFolderThrowsRatherThanReportingEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try WatchFolderInput.snapshot(folder: missing, fileNamePrefix: nil),
                             "a listing failure must be reported as an error, not as an empty folder")
    }

    // MARK: - The snapshot is bound to the folder and filter it was taken for

    /// The confirmation is answered later; if the operator changes folder or prefix in between,
    /// the snapshot describes something else and must not be used to exclude anything.
    func testSnapshotIsBoundToItsFolderAndFilter() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)

        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        XCTAssertTrue(snapshot.covers(folder: dir, fileNamePrefix: "Light_"))
        XCTAssertFalse(snapshot.covers(folder: other, fileNamePrefix: "Light_"), "folder changed")
        XCTAssertFalse(snapshot.covers(folder: dir, fileNamePrefix: "Sub_"), "filter changed")
        XCTAssertFalse(snapshot.covers(folder: dir, fileNamePrefix: nil), "filter cleared")
    }

    // MARK: - Exclusion by identity

    func testMismatchedExclusionRefusesStartup() throws {
        let dir = try makeTempDir(), other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        for (folder, prefix) in [(other, "Light_"), (dir, "Sub_")] {
            let source = FolderFrameSource(folder: folder, mode: .live, fileNamePrefix: prefix,
                                           excludingPreExisting: snapshot)
            defer { source.stop() }
            XCTAssertThrowsError(try source.start(), "must not silently include all files")
        }
    }

    func testSnapshotFailurePreservesActionableDescription() {
        let folder = URL(fileURLWithPath: "/missing/capture-folder")
        let error = WatchFolderInput.SnapshotFailure(folder: folder, reason: "permission denied")
        XCTAssertTrue(error.localizedDescription.contains(folder.path))
        XCTAssertTrue(error.localizedDescription.contains("permission denied"))
    }

    /// "New arrivals only": the subs named in the snapshot are not stacked.
    func testPreExistingSubsInTheSnapshotAreNotStacked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)
        try writeFITS(dir, name: "Light_002.fit", value: 0.2)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        try writeFITS(dir, name: "Light_new.fit", value: 0.3)

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_",
                                       excludingPreExisting: snapshot)
        try source.start()
        let stacked = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(stacked, ["Light_new.fit"], "old inputs excluded while the source demonstrably delivers new input")
    }

    /// The race the preflight must not lose: a sub that lands AFTER the snapshot — including
    /// while the confirmation dialog is still open — was never "existing" and must be stacked.
    func testSubArrivingAfterTheSnapshotIsStacked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_",
                                       excludingPreExisting: snapshot)
        try writeFITS(dir, name: "Light_002.fit", value: 0.2)   // arrives during the dialog
        try source.start()
        let stacked = await framesDelivered(from: source, within: 6)
        XCTAssertEqual(stacked, ["Light_002.fit"],
                       "a capture landing after the snapshot must never be swallowed by exclusion")
    }

    /// Exclusion is keyed on IDENTITY, not name: a snapshot entry whose file has since changed
    /// (dev/ino/size/mtime differ) is no longer the file that was excluded, so it is stacked.
    /// This is what protects a sub that was still being written when the snapshot was taken —
    /// its size and mtime move as it grows.
    func testSubWhoseIdentityChangedAfterTheSnapshotIsStacked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1, width: 64)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")

        // Rewrite it larger — the identity the snapshot recorded no longer describes this file.
        try writeFITS(dir, name: "Light_001.fit", value: 0.1, width: 128)

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_",
                                       excludingPreExisting: snapshot)
        try source.start()
        let stacked = await framesDelivered(from: source, within: 6)
        XCTAssertEqual(stacked, ["Light_001.fit"],
                       "exclusion must not survive the file changing underneath it")
    }

    /// The honest converse, and the LIMIT of the contract: identity comparison detects CHANGE.
    /// A file whose dev/ino/size/mtime are all unchanged is treated as pre-existing — the
    /// mechanism cannot see a write that leaves every stat field identical.
    func testSubWithUnchangedIdentityStaysExcluded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFITS(dir, name: "Light_001.fit", value: 0.1)
        let snapshot = try WatchFolderInput.snapshot(folder: dir, fileNamePrefix: "Light_")
        try writeFITS(dir, name: "Light_new.fit", value: 0.3)

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_",
                                       excludingPreExisting: snapshot)
        try source.start()
        let stacked = await framesDelivered(from: source, within: 5)
        XCTAssertEqual(stacked, ["Light_new.fit"], "unchanged identity excluded; positive control delivered")
    }
}
