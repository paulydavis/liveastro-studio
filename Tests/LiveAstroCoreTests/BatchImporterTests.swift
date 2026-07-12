import XCTest
@testable import LiveAstroCore

final class BatchImporterTests: XCTestCase {
    // Gray CFA starfield (same generator as StackEngineTests).
    func cfaFrame(stars: [(x: Double, y: Double)], name: String) -> RawFrame {
        let width = 512, height = 512
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }
    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    // In-memory FrameSource yielding a fixed list.
    final class ArrayFrameSource: FrameSource {
        let list: [RawFrame]
        init(_ list: [RawFrame]) { self.list = list }
        var frames: AsyncStream<RawFrame> {
            AsyncStream { cont in
                for f in list { cont.yield(f) }
                cont.finish()
            }
        }
        var isFinite: Bool { true }
        var totalCount: Int? { list.count }
        func start() throws {}
        func stop() {}
    }

    /// N registerable subs: a seed plus jittered copies.
    func makeSubs(_ n: Int) -> [RawFrame] {
        var subs = [cfaFrame(stars: field, name: "sub_000.fit")]
        for i in 1..<n {
            let dx = Double(i % 5) * 1.3 - 2.0, dy = Double(i % 3) * 1.1 - 1.0
            let shifted = field.map { (x: $0.x + dx, y: $0.y + dy) }
            subs.append(cfaFrame(stars: shifted, name: String(format: "sub_%03d.fit", i)))
        }
        return subs
    }

    /// Serial reference: process every sub through the monolithic path.
    func serialStack(_ subs: [RawFrame]) -> (mean: [Float], coverage: [Float], accepted: Int, rejected: Int) {
        let e = StackEngine()
        for f in subs { _ = e.process(f) }
        return (e.currentStack()!.pixels, e.currentCoverage()!, e.acceptedCount, e.rejectedCount)
    }

    func testBatchMatchesSerialCountsAndCoverageAndMeanWithinEpsilon() async {
        let subs = makeSubs(12)
        let ref = serialStack(subs)

        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 4)
        var committed = 0, rejected = 0
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in committed += 1 },
                           onRejected: { _ in rejected += 1 },
                           isCancelled: { false })

        XCTAssertEqual(engine.acceptedCount, ref.accepted)
        XCTAssertEqual(engine.rejectedCount, ref.rejected)
        XCTAssertEqual(committed, ref.accepted)
        XCTAssertEqual(rejected, ref.rejected)
        // Coverage (binary-mask sums) is order-independent → exact.
        XCTAssertEqual(engine.currentCoverage()!, ref.coverage)
        // Mean differs only by float accumulation order → within epsilon.
        let mean = engine.currentStack()!.pixels
        XCTAssertEqual(mean.count, ref.mean.count)
        let maxDiff = zip(mean, ref.mean).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-4)
    }

    func testSeedsOnFirstStarryFrameSkippingLeadingBlank() async {
        var subs = [cfaFrame(stars: [], name: "blank.fit")]     // leading, too few stars
        subs.append(contentsOf: makeSubs(3))
        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 2)
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
        XCTAssertEqual(engine.rejectedCount, 1)      // the blank
        XCTAssertEqual(engine.acceptedCount, 3)      // seed + 2
    }

    func testAllSubsAccountedFor() async {
        let subs = makeSubs(10)
        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 3)
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
        XCTAssertEqual(engine.acceptedCount + engine.rejectedCount, subs.count)
    }

    func testStressRepeatedRunsStayConsistent() async {
        let subs = makeSubs(16)
        for _ in 0..<5 {
            let engine = StackEngine()
            let importer = BatchImporter(engine: engine, poolSize: 6)
            await importer.run(source: ArrayFrameSource(subs),
                               onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
            XCTAssertEqual(engine.acceptedCount + engine.rejectedCount, subs.count)
            XCTAssertEqual(engine.acceptedCount, 16)   // all register
        }
    }
}
