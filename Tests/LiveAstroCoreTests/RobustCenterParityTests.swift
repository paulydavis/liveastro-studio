import XCTest
@testable import LiveAstroCore

final class RobustCenterParityTests: XCTestCase {
    // Frozen serial reference from v3.6.5. Do not call production median here:
    // a changed median, wrong channel offset, or skipped row must change the result.
    private func serial(_ sample: [(image: AstroImage, mask: [Float])])
        -> (center: [Float], scale: [Float], covered: [Bool]) {
        let image = sample[0].image
        let plane = image.width * image.height
        var center = [Float](repeating: 0, count: image.pixels.count)
        var scale = center
        var covered = [Bool](repeating: false, count: plane)
        func middle(_ sorted: [Float]) -> Float {
            let m = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2
        }
        for p in 0..<plane { covered[p] = sample.contains { $0.mask[p] > 0 } }
        for i in center.indices {
            let values = sample.filter { $0.mask[i % plane] > 0 }.map { $0.image.pixels[i] }.sorted()
            if values.isEmpty { continue }
            let median = middle(values)
            center[i] = median
            scale[i] = 1.4826 * middle(values.map { abs($0 - median) }.sorted())
        }
        return (center, scale, covered)
    }

    private func check(width: Int, height: Int, channels: Int, frames: Int,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let plane = width * height
        let sample = (0..<frames).map { frame -> (image: AstroImage, mask: [Float]) in
            let pixels = (0..<(plane * channels)).map { i -> Float in
                // Different channels, ties, negatives, bright outliers, and nontrivial Float bits.
                if (i + frame) % 19 == 0 { return 9 }
                return Float((i * 37 + frame * 131) % 997 - 200) / 997
            }
            let mask = (0..<plane).map { p -> Float in
                if p % 17 == 0 { return 0 } // no frame covers this pixel
                if (p + frame) % 5 == 0 { return -1 }
                return frame % 2 == 0 ? 1 : 0.25
            }
            return (AstroImage(width: width, height: height, channels: channels,
                               pixels: pixels, sourceIsLinear: true), mask)
        }
        let expected = serial(sample)
        for _ in 0..<3 {
            let actual = try XCTUnwrap(GlobalCombine.robustCenter(sample: sample), file: file, line: line)
            XCTAssertEqual(actual.center.width, width, file: file, line: line)
            XCTAssertEqual(actual.center.height, height, file: file, line: line)
            XCTAssertEqual(actual.center.channels, channels, file: file, line: line)
            XCTAssertTrue(actual.center.sourceIsLinear, file: file, line: line)
            XCTAssertTrue(actual.center.pixels.map(\.bitPattern) == expected.center.map(\.bitPattern),
                          "center pixels differ from serial reference", file: file, line: line)
            XCTAssertTrue(actual.scale.map(\.bitPattern) == expected.scale.map(\.bitPattern),
                          "MAD pixels differ from serial reference", file: file, line: line)
            XCTAssertEqual(actual.sampleCovered, expected.covered, file: file, line: line)
        }
    }

    func testRGBUnevenRowBandsMatchSerialBits() throws {
        try check(width: 23, height: 137, channels: 3, frames: 8)
    }

    func testMonoOddSampleMatchesSerialBits() throws {
        try check(width: 19, height: 131, channels: 1, frames: 7)
    }

    func testSmallSerialFallbackMatchesSerialBits() throws {
        try check(width: 11, height: 3, channels: 3, frames: 5)
    }

    // AstroImage permits this shape because the dimension product is positive.
    // An optimization must not silently skip pixels the serial flattened loop visited.
    func testPairedNegativeDimensionsPreserveFlattenedBehavior() throws {
        let image = AstroImage(width: -1, height: -1, channels: 1, pixels: [3], sourceIsLinear: true)
        let result = try XCTUnwrap(GlobalCombine.robustCenter(sample: [(image, [1])]))
        XCTAssertEqual(result.center.pixels, [3])
        XCTAssertEqual(result.sampleCovered, [true])
    }

    func testLargeSamplePreservesEveryContributor() throws {
        // A large sample of tiny images must not require one stack frame per input.
        // Varying values pins the full sample median, rather than accepting truncation.
        let sample: [(image: AstroImage, mask: [Float])] = (0..<10_000).map {
            (AstroImage(width: 1, height: 1, channels: 1, pixels: [Float($0)], sourceIsLinear: true), [1])
        }
        let result = try XCTUnwrap(GlobalCombine.robustCenter(sample: sample))
        XCTAssertEqual(result.center.pixels, [4999.5])
        XCTAssertEqual(result.scale, [Float(1.4826) * 2500])
        XCTAssertEqual(result.sampleCovered, [true])
    }

    func testEvenMedianAndMADHaveHandCalculatedValues() throws {
        let sample: [(image: AstroImage, mask: [Float])] = [Float(1), 3, 7, 9].map {
            (AstroImage(width: 1, height: 1, channels: 1, pixels: [$0], sourceIsLinear: true), [1])
        }
        let actual = try XCTUnwrap(GlobalCombine.robustCenter(sample: sample))
        XCTAssertEqual(actual.center.pixels, [5])
        XCTAssertEqual(actual.scale[0], Float(4.4478), accuracy: 0.000001)
        XCTAssertEqual(actual.sampleCovered, [true])
    }
}
