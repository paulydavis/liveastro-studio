import XCTest
@testable import LiveAstroCore

final class ProcessorTests: XCTestCase {
    func testBackendIsCodableStringEnum() throws {
        XCTAssertEqual(ProcessorBackend.allCases, [.none, .graxpert, .nativeDenoise])
        let data = try JSONEncoder().encode(ProcessorBackend.graxpert)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"graxpert\"")
        XCTAssertEqual(try JSONDecoder().decode(ProcessorBackend.self, from: data), .graxpert)
        let nrData = try JSONEncoder().encode(ProcessorBackend.nativeDenoise)
        XCTAssertEqual(String(data: nrData, encoding: .utf8), "\"nativeDenoise\"")
        XCTAssertEqual(try JSONDecoder().decode(ProcessorBackend.self, from: nrData), .nativeDenoise)
    }

    func testProcessorErrorEquatable() {
        XCTAssertEqual(ProcessorError.noOutput, ProcessorError.noOutput)
        XCTAssertEqual(ProcessorError.stepFailed(cmd: "denoising", code: 1),
                       ProcessorError.stepFailed(cmd: "denoising", code: 1))
        XCTAssertNotEqual(ProcessorError.notAvailable, ProcessorError.noOutput)
    }

    // A trivial conforming type proves the protocol shape compiles/usable.
    private struct StubProcessor: Processor {
        var name = "Stub"; var isAvailable = true
        func process(masterURL: URL, outputURL: URL, log: ((String)->Void)?) throws -> URL { log?("ran"); return outputURL }
    }
    func testProtocolIsUsable() throws {
        var msgs: [String] = []
        let p: Processor = StubProcessor()
        let output = try p.process(masterURL: URL(fileURLWithPath: "/a"), outputURL: URL(fileURLWithPath: "/b")) { msgs.append($0) }
        XCTAssertEqual(p.name, "Stub"); XCTAssertTrue(p.isAvailable); XCTAssertEqual(msgs, ["ran"])
        XCTAssertEqual(output.path, "/b")
    }
}
