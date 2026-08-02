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
