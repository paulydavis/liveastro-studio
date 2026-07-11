import XCTest
@testable import LiveAstroCore

final class GraXpertProcessorTests: XCTestCase {
    // Fake runner: records every call; optionally creates the -output file to
    // simulate GraXpert writing its result; returns a scripted exit code per call.
    final class FakeRunner: ProcessRunner {
        var calls: [[String]] = []
        var exitCodes: [Int32]
        var writeOutputOnCallIndex: Int?   // create the file named after this call's -output
        init(exitCodes: [Int32], writeOutputOnCallIndex: Int? = nil) {
            self.exitCodes = exitCodes; self.writeOutputOnCallIndex = writeOutputOnCallIndex
        }
        func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 {
            let idx = calls.count
            calls.append(arguments)
            if writeOutputOnCallIndex == idx, let oi = arguments.firstIndex(of: "-output"), oi+1 < arguments.count {
                FileManager.default.createFile(atPath: arguments[oi+1], contents: Data("fake".utf8))
            }
            return idx < exitCodes.count ? exitCodes[idx] : 0
        }
    }
    // Fake runner that writes the .fits sibling of the denoise -output path,
    // simulating GraXpert appending ".fits" to the requested output stem.
    final class FitsExtFakeRunner: ProcessRunner {
        var calls: [[String]] = []
        var exitCodes: [Int32]
        init(exitCodes: [Int32]) { self.exitCodes = exitCodes }
        func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 {
            let idx = calls.count
            calls.append(arguments)
            // On the second call (denoising), write <output-stem>.fits instead of .fit
            if idx == 1, let oi = arguments.firstIndex(of: "-output"), oi+1 < arguments.count {
                let requestedURL = URL(fileURLWithPath: arguments[oi+1])
                let fitsURL = requestedURL.deletingPathExtension().appendingPathExtension("fits")
                FileManager.default.createFile(atPath: fitsURL.path, contents: Data("fake".utf8))
            }
            return idx < exitCodes.count ? exitCodes[idx] : 0
        }
    }

    private var tmp: URL!
    private var exeFile: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("master.fit").path, contents: Data("m".utf8))
        exeFile = tmp.appendingPathComponent("graxpert_exe")
        FileManager.default.createFile(atPath: exeFile.path, contents: Data("fake".utf8))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testRunsBgThenDenoiseWithExpectedArgs() throws {
        let runner = FakeRunner(exitCodes: [0, 0], writeOutputOnCallIndex: 1)
        let exe = URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
        let proc = GraXpertProcessor(executable: exe, runner: runner, denoiseStrength: 0.5)
        let master = tmp.appendingPathComponent("master.fit")
        let out = tmp.appendingPathComponent("master_processed.fit")
        try proc.process(masterURL: master, outputURL: out, log: nil)

        XCTAssertEqual(runner.calls.count, 2)
        // call 0 = background-extraction
        XCTAssertTrue(runner.calls[0].contains("background-extraction"))
        XCTAssertEqual(zip(runner.calls[0], runner.calls[0].dropFirst()).first { $0.0 == "-gpu" }?.1, "false")
        XCTAssertEqual(runner.calls[0].last, master.path)   // input is the master
        // call 1 = denoising with strength 0.5, input = the bg temp (call 0's -output)
        XCTAssertTrue(runner.calls[1].contains("denoising"))
        let sIdx = runner.calls[1].firstIndex(of: "-strength")!
        XCTAssertEqual(runner.calls[1][sIdx+1], "0.5")
        let bgOutIdx = runner.calls[0].firstIndex(of: "-output")!
        XCTAssertEqual(runner.calls[1].last, runner.calls[0][bgOutIdx+1])  // denoise input == bg output
        let dOutIdx = runner.calls[1].firstIndex(of: "-output")!
        XCTAssertEqual(runner.calls[1][dOutIdx+1], out.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    func testStep1FailureThrowsAndSkipsStep2() throws {
        let runner = FakeRunner(exitCodes: [3, 0])
        let proc = GraXpertProcessor(executable: exeFile, runner: runner)
        XCTAssertThrowsError(try proc.process(masterURL: tmp.appendingPathComponent("master.fit"),
                                              outputURL: tmp.appendingPathComponent("o.fit"), log: nil)) { err in
            XCTAssertEqual(err as? ProcessorError, .stepFailed(cmd: "background-extraction", code: 3))
        }
        XCTAssertEqual(runner.calls.count, 1)   // step 2 never ran
    }

    func testMissingOutputThrowsNoOutput() throws {
        // both steps exit 0 but nothing writes the output file
        let runner = FakeRunner(exitCodes: [0, 0], writeOutputOnCallIndex: nil)
        let proc = GraXpertProcessor(executable: exeFile, runner: runner)
        XCTAssertThrowsError(try proc.process(masterURL: tmp.appendingPathComponent("master.fit"),
                                              outputURL: tmp.appendingPathComponent("o.fit"), log: nil)) { err in
            XCTAssertEqual(err as? ProcessorError, .noOutput)
        }
    }

    func testAcceptsFitsExtensionOutput() throws {
        // GraXpert writes master_processed.fits instead of the requested .fit —
        // the processor should succeed rather than throw .noOutput.
        let proc = GraXpertProcessor(executable: exeFile, runner: FitsExtFakeRunner(exitCodes: [0, 0]))
        let master = tmp.appendingPathComponent("master.fit")
        let out = tmp.appendingPathComponent("master_processed.fit")
        // Should NOT throw — .fits sibling exists even though .fit does not.
        XCTAssertNoThrow(try proc.process(masterURL: master, outputURL: out, log: nil))
        // The .fit itself should not exist; the .fits sibling should.
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.deletingPathExtension().appendingPathExtension("fits").path))
    }

    func testIsAvailableReflectsExecutableExistence() {
        let present = GraXpertProcessor(executable: tmp.appendingPathComponent("master.fit")) // exists
        XCTAssertTrue(present.isAvailable)
        let absent = GraXpertProcessor(executable: tmp.appendingPathComponent("nope"))
        XCTAssertFalse(absent.isAvailable)
    }
}
