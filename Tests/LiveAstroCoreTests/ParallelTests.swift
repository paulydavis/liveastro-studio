import XCTest
@testable import LiveAstroCore

final class ParallelTests: XCTestCase {
    func testBandsCoverEveryRowExactlyOnce() {
        for height in [1, 7, 64, 100, 257, 1000] {
            var counts = [Int](repeating: 0, count: height)
            let lock = NSLock()
            Parallel.rows(height, minRows: 0) { rows in          // minRows 0 → force parallel
                var local: [Int] = []
                for y in rows { local.append(y) }
                lock.withLock { for y in local { counts[y] += 1 } }
            }
            XCTAssertTrue(counts.allSatisfy { $0 == 1 }, "height \(height): each row visited exactly once")
        }
    }

    func testSerialPathBelowThresholdIsOneBand() {
        var ranges: [Range<Int>] = []
        Parallel.rows(10, minRows: 64) { ranges.append($0) }     // 10 < 64 → serial
        XCTAssertEqual(ranges, [0..<10])
    }

    func testZeroHeightRunsNothing() {
        var called = false
        Parallel.rows(0, minRows: 0) { _ in called = true }
        XCTAssertFalse(called)
    }
}
