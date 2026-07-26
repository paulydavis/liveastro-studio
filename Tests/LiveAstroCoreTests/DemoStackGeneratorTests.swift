import XCTest
@testable import LiveAstroCore

final class DemoStackGeneratorTests: XCTestCase {
    func testRunStopsWhenContinuationPredicateTurnsFalse() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var checks = 0
        try DemoStackGenerator.run(
            arguments: ["demo-stack", folder.path, "--interval", "0", "--count", "5"],
            programName: "demo-stack",
            shouldContinue: {
                checks += 1
                return checks <= 2
            })

        XCTAssertEqual(checks, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("live_stack.fit").path))
    }
}
