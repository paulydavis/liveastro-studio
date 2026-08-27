import XCTest
@testable import LiveAstroCore

/// Task 7: RestackCoordinator is the pure core of "rebuild the master from raw subs
/// minus a flagged set." The golden test (testRestackEqualsFreshStackOfSurvivors) pins
/// byte-identity against a fresh stack of the same survivors driven the identical way
/// (same loader, same process()-every-frame order) — see class doc in
/// RestackCoordinator.swift for why that equivalence is the whole point of the design.
final class RestackCoordinatorTests: XCTestCase {
    /// Mono starfield FITS subs written to disk (mirrors NativePipelineTests.writeSub),
    /// so the loader path under test (FolderFrameSource.loadRawFrame) is exercised for
    /// real, not bypassed with in-memory RawFrames.
    private let baseField: [(Double, Double)] = {
        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        return field
    }()

    private func writeSub(_ dir: URL, name: String, dx: Double, dy: Double) throws -> URL {
        let stars = baseField.map { ($0.0 + dx, $0.1 + dy) }
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx2 = Double(x) - s.0, dy2 = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx2 * dx2 + dy2 * dy2) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let url = dir.appendingPathComponent(name)
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px).write(to: url)
        return url
    }

    /// Writes N synthetic FITS subs (small, distinct per-frame translations so
    /// registration against whichever frame becomes the reference is well-conditioned)
    /// to a fresh temp dir; returns their URLs in write order.
    private func writeSubs(_ n: Int) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            try writeSub(dir, name: "sub_\(i).fit", dx: Double(i) * 1.3, dy: -Double(i) * 0.7)
        }
    }

    private func makeEngine() -> StackEngine { StackEngine() }

    /// Reference "fresh stack": load each URL through the SAME loader RestackCoordinator
    /// uses (FolderFrameSource.loadRawFrame) and process() each in order through a fresh
    /// engine — the exact sequence restack() performs. Any divergence here (loader,
    /// order, seeding mechanism) would make the byte-identity assertion meaningless.
    private func stackDirectly(_ urls: [URL]) throws -> AstroImage {
        let engine = makeEngine()
        for url in urls {
            let frame = try FolderFrameSource.loadRawFrame(url: url)
            _ = engine.process(frame)
        }
        return try XCTUnwrap(engine.currentStack())
    }

    func testRestackEqualsFreshStackOfSurvivors() throws {
        let urls = try writeSubs(5)
        let excluded: Set<String> = [urls[2].lastPathComponent]
        let report = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: excluded,
                                                    makeEngine: makeEngine)

        let survivors = urls.enumerated().filter { $0.offset != 2 }.map(\.element)
        let reference = try stackDirectly(survivors)

        XCTAssertEqual(report.master.pixels, reference.pixels)   // byte-identical, exact ==
        XCTAssertEqual(report.stackedCount, 4)
        XCTAssertEqual(report.skippedMissing, 0)
    }

    func testFlagIsOrderIndependent() throws {
        let urls = try writeSubs(4)
        let a = try RestackCoordinator.restack(
            rawURLs: urls, excludingSourceFiles: [urls[1].lastPathComponent, urls[3].lastPathComponent],
            makeEngine: makeEngine)
        let b = try RestackCoordinator.restack(
            rawURLs: urls, excludingSourceFiles: [urls[3].lastPathComponent, urls[1].lastPathComponent],
            makeEngine: makeEngine)
        XCTAssertEqual(a.master.pixels, b.master.pixels)
    }

    func testAllExcludedThrowsNoSurviving() throws {
        let urls = try writeSubs(3)
        let all = Set(urls.map(\.lastPathComponent))
        XCTAssertThrowsError(try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: all,
                                                             makeEngine: makeEngine)) {
            XCTAssertEqual($0 as? RestackError, .noSurvivingSubs)
        }
    }

    /// The `prepare` closure (production: the session's calibrator, Fix 1) must run on EVERY
    /// surviving loaded frame BEFORE it reaches the engine, and the prepared frame — not the
    /// raw one — is what gets stacked. Proves the AppModel wiring's contract: a calibrator
    /// passed as `prepare` actually calibrates the re-stacked master.
    func testPrepareAppliedToEverySurvivingFrame() throws {
        let urls = try writeSubs(4)
        let excluded: Set<String> = [urls[1].lastPathComponent]

        var prepareCount = 0
        let report = try RestackCoordinator.restack(
            rawURLs: urls, excludingSourceFiles: excluded, makeEngine: makeEngine,
            prepare: { frame in prepareCount += 1; return frame })
        XCTAssertEqual(prepareCount, 3, "prepare runs once per surviving loadable frame (4 written − 1 excluded)")
        XCTAssertEqual(report.stackedCount, 3)

        // A non-identity prepare must change the master vs. identity — i.e. the PREPARED
        // pixels are what the engine stacks, not the raw ones.
        let identity = try RestackCoordinator.restack(
            rawURLs: urls, excludingSourceFiles: excluded, makeEngine: makeEngine)
        let scaled = try RestackCoordinator.restack(
            rawURLs: urls, excludingSourceFiles: excluded, makeEngine: makeEngine,
            prepare: { frame in
                let img = AstroImage(width: frame.image.width, height: frame.image.height,
                                     channels: frame.image.channels,
                                     pixels: frame.image.pixels.map { $0 * 0.5 },
                                     sourceIsLinear: frame.image.sourceIsLinear)
                return RawFrame(image: img, bayerPattern: frame.bayerPattern, bottomUp: frame.bottomUp,
                                timestamp: frame.timestamp, sourceName: frame.sourceName,
                                metadata: frame.metadata)
            })
        XCTAssertNotEqual(identity.master.pixels, scaled.master.pixels)
    }

    func testMissingRawCountedAsSkipped() throws {
        var urls = try writeSubs(3)
        urls.append(URL(fileURLWithPath: "/nonexistent/ghost.fit"))
        let report = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: [], makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMissing, 1)
        XCTAssertEqual(report.stackedCount, 3)
    }
}
