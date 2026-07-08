import XCTest
@testable import LiveAstroCore

final class AtomicCounterTests: XCTestCase {
    func testStartsAtZero() {
        XCTAssertEqual(AtomicCounter().value, 0)
    }

    func testConcurrentIncrementsAllLand() async {
        let counter = AtomicCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<100 { counter.increment() }
                }
            }
        }
        XCTAssertEqual(counter.value, 200)
    }
}
