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
