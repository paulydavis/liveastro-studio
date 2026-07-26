import XCTest
@testable import LiveAstroCore

final class DirectoryFootprintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("footprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testByteCountSumsNestedRegularFiles() throws {
        try Data(repeating: 0x01, count: 10).write(to: root.appendingPathComponent("a.bin"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 25).write(to: nested.appendingPathComponent("b.bin"))

        let bytes = try DirectoryFootprint.byteCount(at: root)

        XCTAssertEqual(bytes, 35)
    }

    func testByteCountReturnsZeroForEmptyDirectory() throws {
        XCTAssertEqual(try DirectoryFootprint.byteCount(at: root), 0)
    }

    func testByteCountThrowsForMissingRoot() throws {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try DirectoryFootprint.byteCount(at: missing))
    }
}
