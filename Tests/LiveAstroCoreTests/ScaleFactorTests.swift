// Tests/LiveAstroCoreTests/ScaleFactorTests.swift
import XCTest
@testable import LiveAstroCore

final class ScaleFactorTests: XCTestCase {
    func testMedianRatioOfMatchedFluxes() {
        // sub uniformly 20% dimmer → ratios all 1.25 → s = 1.25
        let pairs = (1...9).map { (sub: Double($0) * 0.8, ref: Double($0)) }
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.25, accuracy: 1e-5)
    }
    func testMedianRobustToOutlierPairs() {
        var pairs = (1...9).map { (sub: Double($0), ref: Double($0)) }   // s = 1
        pairs[0].ref = 100; pairs[1].sub = 100                            // two wild mismatches
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.0, accuracy: 1e-5)
    }
    func testClampedToRange() {
        let dim = (1...9).map { (sub: Double($0) * 0.1, ref: Double($0)) }   // ratio 10 → clamp 2.0
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: dim), 2.0)
        let bright = (1...9).map { (sub: Double($0) * 10, ref: Double($0)) } // ratio 0.1 → clamp 0.5
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: bright), 0.5)
    }
    func testTooFewPairsIsOne() {
        let pairs = (1...4).map { (sub: Double($0), ref: Double($0) * 2) }
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.0)
    }
    func testInvalidFluxPairsSkipped() {
        // 5 good pairs at ratio 1.5 + junk pairs (0 / negative / NaN) that must be ignored
        var pairs = (1...5).map { (sub: Double($0), ref: Double($0) * 1.5) }
        pairs.append((sub: 0, ref: 3)); pairs.append((sub: -1, ref: 2)); pairs.append((sub: .nan, ref: 1))
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.5, accuracy: 1e-5)
    }
}
