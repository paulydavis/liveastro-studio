import XCTest
@testable import LiveAstroCore

final class NativeDenoiseProcessorTests: XCTestCase {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 96x96 3-channel noisy master (deterministic).
    private func writeMaster(_ url: URL) throws -> [Float] {
        var rng: UInt64 = 0xCAFE_0002
        let px = (0..<(96 * 96 * 3)).map { _ -> Float in
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.05 + Float(rng >> 33) / Float(1 << 31) * 0.03
        }
        try FITSWriter.float32(width: 96, height: 96, channels: 3, pixels: px).write(to: url)
        return px
    }

    func testRoundTripWritesDenoisedOutputAndReturnsOutputURL() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        let inputPixels = try writeMaster(master)
        let masterBytes = try Data(contentsOf: master)
        var logs: [String] = []
        let produced = try NativeDenoiseProcessor(strength: 0.8)
            .process(masterURL: master, outputURL: out) { logs.append($0) }
        XCTAssertEqual(produced, out)                          // produced-URL contract: exactly outputURL
        let img = try FITSReader.readLinear(try Data(contentsOf: produced))
        XCTAssertEqual(img.width, 96); XCTAssertEqual(img.height, 96)
        XCTAssertEqual(img.channels, 3)
        XCTAssertNotEqual(img.pixels, inputPixels)             // linear-domain engine engaged
        XCTAssertEqual(try Data(contentsOf: master), masterBytes)   // master.fit never mutated
        XCTAssertFalse(logs.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".native-denoise-") }, "temp file leaked")
    }

    func testStrengthZeroWritesPixelEquivalentOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        let inputPixels = try writeMaster(master)
        _ = try NativeDenoiseProcessor(strength: 0)
            .process(masterURL: master, outputURL: out, log: nil)
        let img = try FITSReader.readLinear(try Data(contentsOf: out))
        XCTAssertEqual(img.pixels, inputPixels)                // engine passthrough, still a valid file
    }

    func testOverwritesExistingOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        _ = try writeMaster(master)
        try Data("stale".utf8).write(to: out)
        _ = try NativeDenoiseProcessor(strength: 0.5).process(masterURL: master, outputURL: out, log: nil)
        XCTAssertNoThrow(try FITSReader.readHeader(try Data(contentsOf: out)))   // real FITS replaced the stale file
    }

    /// Replacement failures must never destroy a prior good output
    /// (Paul's post-merge P2 finding: remove-then-move window).
    /// The failing FileManager intercepts both the legacy moveItem path and the
    /// atomic replaceItem path, simulating a swap failure AFTER the temp write.
    func testPriorOutputSurvivesFailedReplacement() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        let out = dir.appendingPathComponent("master_processed.fit")
        _ = try writeMaster(master)
        let priorBytes = Data("prior good processed master".utf8)
        try priorBytes.write(to: out)

        let failing = ReplacementFailingFileManager()
        XCTAssertThrowsError(try NativeDenoiseProcessor(strength: 0.5, fileManager: failing)
            .process(masterURL: master, outputURL: out, log: nil))
        XCTAssertEqual(try Data(contentsOf: out), priorBytes,
                       "prior good output must survive a failed replacement")
    }

    // MARK: - FileReplace helper contract

    func testFileReplaceReplacesExistingDestinationAndConsumesTemp() throws {
        let dir = try sandbox()
        let dest = dir.appendingPathComponent("dest.bin")
        let temp = dir.appendingPathComponent("temp.bin")
        try Data("old".utf8).write(to: dest)
        try Data("new".utf8).write(to: temp)
        try FileReplace.replaceItem(at: dest, withItemAt: temp)
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testFileReplaceMovesWhenNoDestinationExists() throws {
        let dir = try sandbox()
        let dest = dir.appendingPathComponent("dest.bin")
        let temp = dir.appendingPathComponent("temp.bin")
        try Data("new".utf8).write(to: temp)
        try FileReplace.replaceItem(at: dest, withItemAt: temp)
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
    }

    func testFileReplacePreservesDestinationWhenReplacementFails() throws {
        let dir = try sandbox()
        let dest = dir.appendingPathComponent("dest.bin")
        let temp = dir.appendingPathComponent("temp.bin")
        try Data("old".utf8).write(to: dest)
        try Data("new".utf8).write(to: temp)
        let failing = ReplacementFailingFileManager()
        XCTAssertThrowsError(try FileReplace.replaceItem(at: dest, withItemAt: temp,
                                                         fileManager: failing))
        XCTAssertEqual(try Data(contentsOf: dest), Data("old".utf8),
                       "destination must be preserved on failure")
    }

    func testMissingMasterThrows() throws {
        let dir = try sandbox()
        XCTAssertThrowsError(try NativeDenoiseProcessor()
            .process(masterURL: dir.appendingPathComponent("absent.fit"),
                     outputURL: dir.appendingPathComponent("out.fit"), log: nil))
    }

    func testFailedWriteLeavesNoPartialOutput() throws {
        let dir = try sandbox()
        let master = dir.appendingPathComponent("master.fit")
        _ = try writeMaster(master)
        let badOut = dir.appendingPathComponent("no-such-dir/master_processed.fit")
        XCTAssertThrowsError(try NativeDenoiseProcessor()
            .process(masterURL: master, outputURL: badOut, log: nil))
        // No partial/temp artifacts anywhere in the session dir.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(names), ["master.fit"])
    }

    func testAlwaysAvailable() {
        XCTAssertTrue(NativeDenoiseProcessor().isAvailable)     // spec §2.3
        XCTAssertEqual(NativeDenoiseProcessor().name, "Native NR")
    }
}

/// Fails every swap primitive while leaving reads/writes/removes intact —
/// simulates "the final replacement failed" without touching earlier steps.
private final class ReplacementFailingFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL,
                              backupItemName: String?,
                              options: FileManager.ItemReplacementOptions = [],
                              resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
