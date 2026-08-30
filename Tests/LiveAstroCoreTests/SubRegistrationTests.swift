import XCTest
@testable import LiveAstroCore

final class SubRegistrationTests: XCTestCase {
    func testSampleAllWhenUnderBudget() {
        XCTAssertEqual(SubRegistration.sampleIndices(count: 8, maxSampleFrames: 20), Array(0..<8))
    }
    func testSampleIsStridedOddDeterministic() {
        let a = SubRegistration.sampleIndices(count: 100, maxSampleFrames: 20)
        let b = SubRegistration.sampleIndices(count: 100, maxSampleFrames: 20)
        XCTAssertEqual(a, b)                                   // deterministic
        XCTAssertEqual(a.count, 19, "cap 20 reduced to odd 19; must NEVER exceed the cap")
        XCTAssertEqual(a.count % 2, 1, "sample count must be odd for a true per-pixel median")
        XCTAssertEqual(a.first, 0)
        XCTAssertTrue(a.allSatisfy { $0 >= 0 && $0 < 100 })
        XCTAssertEqual(a, a.sorted())                          // ascending, strided
    }
    func testSampleNeverExceedsCap() {
        // count 12, cap 4 → EXACTLY the cap reduced to odd (3); RAM is the hard bound, never above it.
        let a = SubRegistration.sampleIndices(count: 12, maxSampleFrames: 4)
        XCTAssertLessThanOrEqual(a.count, 4)                   // never > the RAM cap
        XCTAssertEqual(a.count % 2, 1)                         // odd
        XCTAssertTrue(a.allSatisfy { $0 >= 0 && $0 < 12 })
        XCTAssertEqual(Set(a).count, a.count)                 // distinct
        XCTAssertEqual(SubRegistration.sampleIndices(count: 10, maxSampleFrames: 0), [])   // cap 0 → empty, never [0]
        XCTAssertEqual(SubRegistration.sampleIndices(count: 0, maxSampleFrames: 20), [])   // no survivors → empty
    }
}
