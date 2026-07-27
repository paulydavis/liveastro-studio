import XCTest
@testable import LiveAstroCore

final class ProcessRunnerTests: XCTestCase {
    // Smoke test: the real runner actually launches a process and returns its exit code.
    // Uses /bin/echo (exit 0) and /usr/bin/false (exit 1) — no third-party binary.
    func testFoundationRunnerReturnsExitCodeZero() throws {
        let runner = FoundationProcessRunner()
        var out: [String] = []
        let code = try runner.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                  arguments: ["hello"], log: { out.append($0) })
        XCTAssertEqual(code, 0)
    }

    func testFoundationRunnerReturnsNonZeroExit() throws {
        let runner = FoundationProcessRunner()
        let code = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                  arguments: [], log: nil)
        XCTAssertEqual(code, 1)
    }

    // Prove multi-line output is captured through handler+drain (trailing lines not lost).
    func testCapturesMultiLineOutput() throws {
        let runner = FoundationProcessRunner()
        var lines: [String] = []
        let code = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'alpha\\nbeta\\ngamma\\n'"],
            log: { lines.append($0) }
        )
        XCTAssertEqual(code, 0)
        // Handler and drain timing is nondeterministic; assert on the union (each line present).
        XCTAssertTrue(lines.contains("alpha"), "lines: \(lines)")
        XCTAssertTrue(lines.contains("beta"), "lines: \(lines)")
        XCTAssertTrue(lines.contains("gamma"), "lines: \(lines)")
    }

    func testDrainsLargeOutputWhenLogIsNil() throws {
        let runner = FoundationProcessRunner(timeoutSeconds: 5)
        let code = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 200000"],
            log: nil
        )
        XCTAssertEqual(code, 0)
    }

    func testTimeoutTerminatesHungChild() throws {
        let runner = FoundationProcessRunner(timeoutSeconds: 0.2)
        let start = Date()
        XCTAssertThrowsError(try runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            log: nil
        )) {
            XCTAssertEqual($0 as? ProcessRunnerError, .timedOut(seconds: 0.2))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testTimeoutEscalatesPastSIGTERMIgnoringProcessPromptly() throws {
        let runner = FoundationProcessRunner(timeoutSeconds: 0.1, terminationGraceSeconds: 0.2)
        let start = Date()
        XCTAssertThrowsError(try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30"],
            log: nil
        )) {
            XCTAssertEqual($0 as? ProcessRunnerError, .timedOut(seconds: 0.1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // A fake conforming type proves the protocol is injectable (used heavily in Task 3).
    private class FakeRunner: ProcessRunner {
        var recorded: [(URL, [String])] = []
        func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 {
            recorded.append((executable, arguments)); return 0
        }
    }
    func testFakeRunnerRecords() throws {
        let f = FakeRunner()
        _ = try f.run(executable: URL(fileURLWithPath: "/x"), arguments: ["a","b"], log: nil)
        XCTAssertEqual(f.recorded.count, 1)
        XCTAssertEqual(f.recorded[0].1, ["a","b"])
    }
}
