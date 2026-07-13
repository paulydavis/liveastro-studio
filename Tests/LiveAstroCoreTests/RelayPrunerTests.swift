// Tests/LiveAstroCoreTests/RelayPrunerTests.swift
import XCTest
@testable import LiveAstroCore

final class RelayPrunerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Make a relay-style session dir containing one small file (so bytes > 0).
    @discardableResult
    func makeSession(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: dir.appendingPathComponent("sub.fit"))
        return dir
    }

    func date(_ s: String) -> Date {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar.current; df.timeZone = Calendar.current.timeZone
        return df.date(from: s)!
    }

    // MARK: sessionDate parsing

    func testParsesPlainDate() {
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "M 101-2026-07-09"), date("2026-07-09"))
    }
    func testParsesExposureSuffixedDate() {
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "NGC 6960-2026-07-11-30.0s"), date("2026-07-11"))
    }
    func testTargetWithDigitsAndHyphensParsesLastDateToken() {
        // hostile-ish target name containing a date-shaped fragment earlier in the name
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "Sh2-101-2026-07-09"), date("2026-07-09"))
    }
    func testInvalidCalendarDateIsNil() {
        XCTAssertNil(RelayPruner.sessionDate(fromName: "Target-2026-13-99"))
    }
    func testNoDateIsNil() {
        XCTAssertNil(RelayPruner.sessionDate(fromName: "random-folder"))
    }

    // MARK: prune semantics

    func testDeletesStrictlyOlderKeepsWindowAndToday() throws {
        try makeSession("Old-2026-07-01")            // 12 days before "now" → delete
        try makeSession("Edge-2026-07-06")           // exactly 7 days before → KEEP (strictly older only)
        try makeSession("Recent-2026-07-10")         // inside window → keep
        try makeSession("Today-2026-07-13")          // today → keep
        let removed = RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13"))
        XCTAssertEqual(removed.map(\.name), ["Old-2026-07-01"])
        XCTAssertTrue(removed[0].bytes > 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, ["Edge-2026-07-06", "Recent-2026-07-10", "Today-2026-07-13"])
    }

    func testExcludedDirSurvivesEvenIfOld() throws {
        let dir = try makeSession("Active-2026-01-01")
        let removed = RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13"),
                                        excluding: dir)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testUnparseableNameSurvives() throws {
        try makeSession("my-precious-data")
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("my-precious-data").path))
    }

    func testPlainFileAtRootUntouched() throws {
        let f = root.appendingPathComponent("stray-2026-01-01.txt")
        try Data("x".utf8).write(to: f)
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testZeroOrNegativeDaysIsNoOp() throws {
        try makeSession("Old-2020-01-01")
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 0, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: -3, now: date("2026-07-13")).isEmpty)
    }

    func testMissingRootReturnsEmpty() {
        let ghost = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(RelayPruner.prune(root: ghost, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
    }
}
