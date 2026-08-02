import XCTest
@testable import LiveAstroCore

/// Pins the Swift Denoiser to the Task-1-validated prototype on a real M8 crop
/// (spec §6 "Golden"). Two pins, per the RCD golden lesson:
///  - *_py.f32   : prototype float32 output, 2e-3 tolerance — the cross-language
///                 port-validity gate; generated once by denoise_prototype.py golden,
///                 never regenerated.
///  - *_swift.f32: SHIPPED-Swift output, 1e-6 tolerance — the normative refactor
///                 pin; regenerated only via DUMP_DENOISE_GOLDENS=1 below.
final class DenoiserGoldenTests: XCTestCase {

    private func loadFloats(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures"),
            "\(name).f32 missing from Fixtures")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count % 4, 0)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
    }

    private func goldenInput() throws -> AstroImage {
        let px = try loadFloats("denoise_golden_input")
        XCTAssertEqual(px.count, 64 * 64 * 3)
        return AstroImage(width: 64, height: 64, channels: 3, pixels: px,
                          sourceIsLinear: false)          // display-domain crop (meta json)
    }

    private func assertMatches(_ out: [Float], _ expected: [Float],
                               tolerance: Float, label: String) {
        XCTAssertEqual(out.count, expected.count, "\(label): size mismatch")
        var maxErr: Float = 0
        for i in 0..<out.count {
            let err = abs(out[i] - expected[i])
            if err > maxErr { maxErr = err }
            XCTAssertLessThanOrEqual(err, tolerance,
                "\(label): pixel \(i) got \(out[i]) expected \(expected[i]) diff \(err)")
        }
        print("DenoiserGoldenTests · \(label) maxErr = \(maxErr)")
    }

    func testGoldenCropMatchesPrototype() throws {
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        try assertMatches(out.pixels, loadFloats("denoise_golden_expected_py"),
                          tolerance: 2e-3, label: "py-pin")
    }

    func testGoldenCropMatchesSwiftPin() throws {
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        try assertMatches(out.pixels, loadFloats("denoise_golden_expected_swift"),
                          tolerance: 1e-6, label: "swift-pin")
    }

    // Regeneration utility (RCD DUMP_GOLDENS pattern, DebayerRCDTests.swift:21-58):
    // DUMP_DENOISE_GOLDENS=1 swift test --filter testDumpSwiftGolden
    // writes the shipped implementation's output to a temp file and prints the cp command.
    func testDumpSwiftGolden() throws {
        guard ProcessInfo.processInfo.environment["DUMP_DENOISE_GOLDENS"] == "1" else {
            throw XCTSkip("regeneration utility — set DUMP_DENOISE_GOLDENS=1 to emit the Swift pin")
        }
        let out = Denoiser.apply(try goldenInput(), strength: 0.5)
        var data = Data(capacity: out.pixels.count * 4)
        for v in out.pixels {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("denoise_golden_expected_swift.f32")
        try data.write(to: url)
        print("\n==== DUMP_DENOISE_GOLDENS ====")
        print("cp \(url.path) Tests/LiveAstroCoreTests/Fixtures/denoise_golden_expected_swift.f32")
        print("==== END ====\n")
    }
}
