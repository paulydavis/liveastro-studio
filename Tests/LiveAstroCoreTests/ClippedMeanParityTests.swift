import XCTest
@testable import LiveAstroCore

final class ClippedMeanParityTests: XCTestCase {
    private typealias Frame = (image: AstroImage, mask: [Float], weight: Float)

    // Independent pixel-first oracle. Frame accumulation order and the v3.6.6
    // arithmetic are frozen; no production combine or clipping helpers are used.
    private func reference(_ frames: [Frame], center: AstroImage, scale: [Float],
                           covered: [Bool], kappa: Float) -> ([Float], [Float]) {
        let plane = center.width * center.height
        var output = [Float](repeating: 0, count: center.pixels.count)
        var depth = [Float](repeating: 0, count: plane)
        for p in 0..<plane {
            for frame in frames where frame.mask[p] > 0 { depth[p] += 1 }
            for channel in 0..<center.channels {
                let i = channel * plane + p
                var weight: Float = 0, weighted: Float = 0
                for frame in frames where frame.mask[p] > 0 {
                    let value = frame.image.pixels[i]
                    if covered[p] && abs(value - center.pixels[i]) > kappa * max(scale[i], 1e-7) {
                        continue
                    }
                    weight += frame.weight
                    weighted += frame.weight * value
                }
                if weight > 0 { output[i] = weighted / weight }
                else if depth[p] > 0 { output[i] = center.pixels[i] }
            }
        }
        return (output, depth)
    }

    private func check(width: Int, height: Int, channels: Int,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let plane = width * height
        let n = plane * channels
        let center = AstroImage(width: width, height: height, channels: channels,
                               pixels: (0..<n).map { Float($0 % 11) / 13 }, sourceIsLinear: false)
        let scale = (0..<n).map { $0 % 7 == 0 ? Float(0) : Float($0 % 5) / 19 }
        let covered = (0..<plane).map { $0 % 3 != 0 }
        let frames: [Frame] = (0..<9).map { f in
            let pixels = (0..<n).map { i -> Float in
                if i % 23 == 0 { return 10 } // all-clipped and sample-uncovered cases
                return Float((i * 31 + f * 67) % 1009 - 111) / 1009
            }
            let mask = (0..<plane).map { p -> Float in
                if p % 17 == 0 { return 0 } // genuinely uncovered
                return (p + f) % 5 == 0 ? -1 : 0.25
            }
            return (AstroImage(width: width, height: height, channels: channels,
                               pixels: pixels, sourceIsLinear: true), mask, Float(f % 4) / 3)
        }
        let expected = reference(frames, center: center, scale: scale, covered: covered, kappa: 3)
        for _ in 0..<3 {
            let actual = try XCTUnwrap(GlobalCombine.clippedWeightedMean(
                frames: { AnyIterator(frames.makeIterator()) }, center: center,
                scale: scale, sampleCovered: covered, kappa: 3), file: file, line: line)
            XCTAssertEqual(actual.image.width, width, file: file, line: line)
            XCTAssertEqual(actual.image.height, height, file: file, line: line)
            XCTAssertEqual(actual.image.channels, channels, file: file, line: line)
            XCTAssertFalse(actual.image.sourceIsLinear, file: file, line: line)
            XCTAssertTrue(actual.image.pixels.map(\.bitPattern) == expected.0.map(\.bitPattern),
                          "weighted pixels differ from serial reference", file: file, line: line)
            XCTAssertEqual(actual.coverage.map(\.bitPattern), expected.1.map(\.bitPattern),
                           "coverage counts contributors, not surviving channels", file: file, line: line)
        }
    }

    // Skipping a row/channel, changing mask semantics, or counting only survivors fails these.
    func testRGBUnevenBandsMatchSerialBits() throws { try check(width: 23, height: 137, channels: 3) }
    func testMonoUnevenBandsMatchSerialBits() throws { try check(width: 19, height: 131, channels: 1) }
    func testSmallSerialFallbackMatchesBits() throws { try check(width: 7, height: 3, channels: 3) }
    func testPairedNegativeDimensionsKeepFlattenedBehavior() throws { try check(width: -3, height: -5, channels: 1) }

    // A cross-frame reduction/reordering changes (1e20 + -1e20 + 3) / 3 from 1 to 0.
    func testFrameOrderIsPreservedAndIteratorStaysOnCallingThread() throws {
        let thread = Thread.current
        let values: [Float] = [1e20, -1e20, 3]
        var factories = 0, pulls = 0
        let center = AstroImage(width: 3, height: 137, channels: 3,
                               pixels: [Float](repeating: 0, count: 3 * 137 * 3), sourceIsLinear: true)
        let result = try XCTUnwrap(GlobalCombine.clippedWeightedMean(frames: {
            factories += 1
            return AnyIterator {
                XCTAssertTrue(Thread.current === thread)
                let index = pulls
                pulls += 1
                guard index < values.count else { return nil }
                return (AstroImage(width: 3, height: 137, channels: 3,
                                   pixels: [Float](repeating: values[index], count: 3 * 137 * 3),
                                   sourceIsLinear: true), [Float](repeating: 1, count: 3 * 137), 1)
            }
        }, center: center, scale: [Float](repeating: 1, count: center.pixels.count),
            sampleCovered: [Bool](repeating: false, count: 3 * 137), kappa: 3))
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(pulls, 4)
        XCTAssertTrue(result.image.pixels.allSatisfy { $0.bitPattern == Float(1).bitPattern })
        XCTAssertTrue(result.coverage.allSatisfy { $0 == 3 })
    }

    // Materializing the iterator eagerly would pull past the invalid second frame.
    func testMalformedFrameStopsWithoutPullingLaterFrames() {
        let good = AstroImage(width: 1, height: 1, channels: 1, pixels: [2], sourceIsLinear: true)
        var pulls = 0
        let result = GlobalCombine.clippedWeightedMean(frames: {
            AnyIterator {
                pulls += 1
                guard pulls <= 3 else { return nil }
                return (good, pulls == 2 ? [] : [1], 1)
            }
        }, center: good, scale: [1], sampleCovered: [true], kappa: 3)
        XCTAssertNil(result)
        XCTAssertEqual(pulls, 2)
    }

    func testZeroWidthDoesNotScheduleMeaninglessRows() throws {
        let image = AstroImage(width: 0, height: Int.max, channels: 1, pixels: [], sourceIsLinear: true)
        let result = try XCTUnwrap(GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator([(image: image, mask: [Float](), weight: Float(1))].makeIterator()) },
            center: image, scale: [], sampleCovered: [], kappa: 3))
        XCTAssertTrue(result.image.pixels.isEmpty)
        XCTAssertTrue(result.coverage.isEmpty)
    }

    func testInvalidSampleCoverageNeverCreatesIterator() {
        let image = AstroImage(width: 1, height: 1, channels: 1, pixels: [2], sourceIsLinear: true)
        for covered in [[Bool](), [true, false]] {
            var created = false
            let result = GlobalCombine.clippedWeightedMean(frames: {
                created = true
                return AnyIterator { nil }
            }, center: image, scale: [1], sampleCovered: covered, kappa: 3)
            XCTAssertNil(result)
            XCTAssertFalse(created)
        }
    }

    func testEachDimensionMismatchStopsBeforeNextPull() {
        let good = AstroImage(width: 2, height: 2, channels: 1, pixels: [1, 2, 3, 4], sourceIsLinear: true)
        for (w, h, c) in [(3, 2, 1), (2, 3, 1), (2, 2, 3)] {
            let bad = AstroImage(width: w, height: h, channels: c,
                                 pixels: [Float](repeating: 1, count: w * h * c), sourceIsLinear: true)
            var pulls = 0
            let result = GlobalCombine.clippedWeightedMean(frames: {
                AnyIterator {
                    pulls += 1
                    guard pulls <= 3 else { return nil }
                    let image = pulls == 2 ? bad : good
                    return (image, [Float](repeating: 1, count: image.width * image.height), 1)
                }
            }, center: good, scale: [1, 1, 1, 1], sampleCovered: [true, true, true, true], kappa: 3)
            XCTAssertNil(result)
            XCTAssertEqual(pulls, 2)
        }
    }

    // Preserve existing nonfinite/zero/negative-weight behavior, not a new sanitization policy.
    func testExceptionalValuesMatchSerialBits() throws {
        let width = 8, height = 137, plane = width * height
        let values: [Float] = [.nan, .infinity, -.infinity, -0.0, 0, 1e-8, -1, 2]
        let center = AstroImage(width: width, height: height, channels: 1,
                               pixels: [Float](repeating: 0, count: plane), sourceIsLinear: true)
        let frames: [Frame] = [Float(0), -1, 2, .infinity].map { weight in
            (AstroImage(width: width, height: height, channels: 1,
                        pixels: (0..<plane).map { values[$0 % values.count] }, sourceIsLinear: true),
             [Float](repeating: 1, count: plane), weight)
        }
        let scale = [Float](repeating: 0, count: plane)
        let covered = (0..<plane).map { $0 % 3 == 0 }
        let expected = reference(frames, center: center, scale: scale, covered: covered, kappa: 3)
        let result = try XCTUnwrap(GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.makeIterator()) }, center: center, scale: scale,
            sampleCovered: covered, kappa: 3))
        XCTAssertEqual(result.image.pixels.map(\.bitPattern), expected.0.map(\.bitPattern))
        XCTAssertEqual(result.coverage.map(\.bitPattern), expected.1.map(\.bitPattern))
    }
}
