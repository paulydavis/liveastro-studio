import XCTest
@testable import LiveAstroCore

final class StackEngineFinalizationStateTests: XCTestCase {
    private func starFrame(name: String) -> RawFrame {
        let width = 64
        let height = 64
        var pixels = [Float](repeating: 0.05, count: width * height)
        for y in 29..<35 {
            for x in 29..<35 {
                pixels[y * width + x] = 0.95
            }
        }
        return RawFrame(
            image: AstroImage(width: width, height: height, channels: 1,
                              pixels: pixels, sourceIsLinear: true),
            bayerPattern: nil,
            bottomUp: false,
            timestamp: Date(timeIntervalSince1970: 0),
            sourceName: name
        )
    }

    func testStoredStateTransitionsInitialSeedManualReseedAndReseedAgain() throws {
        let engine = StackEngine(seedMinStars: 1)
        XCTAssertEqual(try engine.finalizationState().stackState, .initialEmpty)
        XCTAssertEqual(engine.process(starFrame(name: "seed")), .becameReference)
        XCTAssertEqual(try engine.finalizationState().stackState, .active)
        engine.reseed()
        XCTAssertEqual(try engine.finalizationState().stackState,
                       .awaitingSeedAfterReseed(manual: 1, auto: 0))
        XCTAssertEqual(engine.process(starFrame(name: "new-seed")), .becameReference)
        XCTAssertEqual(try engine.finalizationState().stackState, .active)
        engine.reseed()
        XCTAssertEqual(try engine.finalizationState().stackState,
                       .awaitingSeedAfterReseed(manual: 2, auto: 0))
    }

    func testStagedSeedAfterReseedTransitionsToActive() throws {
        let engine = StackEngine(seedMinStars: 1)
        engine.reseed()

        XCTAssertTrue(engine.seedReference(starFrame(name: "staged-seed"), minRows: .max))
        let final = try engine.finalizationState()
        XCTAssertEqual(final.stackState, .active)
        XCTAssertEqual(final.frameCount, 1)
    }

    func testFinalizationStateSeparatesCurrentStackFromSessionHistory() throws {
        let engine = StackEngine(seedMinStars: 1)
        _ = engine.process(starFrame(name: "old-seed"))
        engine.reseed()
        _ = engine.process(starFrame(name: "new-seed"))

        let final = try engine.finalizationState()

        XCTAssertEqual(final.stackState, .active)
        XCTAssertEqual(final.frameCount, 1)
        XCTAssertEqual(final.sessionAcceptedCount, 2)
        XCTAssertEqual(final.sessionRejectedCount, 0)
        XCTAssertNotNil(final.image)
        XCTAssertNotNil(final.coverage)
    }

    func testFinalizationStateRefusesActiveStateWithoutAccumulator() throws {
        let engine = StackEngine(seedMinStars: 1)
        XCTAssertEqual(engine.process(starFrame(name: "seed")), .becameReference)
        engine.forceAccumulatorLossForTesting()

        XCTAssertThrowsError(try engine.finalizationState()) { error in
            XCTAssertEqual(error as? StackEngine.FinalizationError, .invariantBreach)
        }
    }

    func testFinalizationStateRefusesInitialEmptyStateWithAcceptedHistory() {
        let engine = StackEngine(seedMinStars: 1)
        engine.forceInitialEmptyAcceptedHistoryForTesting()

        XCTAssertThrowsError(try engine.finalizationState()) { error in
            XCTAssertEqual(error as? StackEngine.FinalizationError, .invariantBreach)
        }
    }
}
