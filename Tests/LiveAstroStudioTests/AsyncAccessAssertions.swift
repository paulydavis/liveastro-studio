import XCTest

@MainActor
func assertAccessEqual<T: Equatable>(_ lhs: @autoclosure () async throws -> T,
                                    _ rhs: @autoclosure () async throws -> T,
                                    _ message: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let a = try await lhs(), b = try await rhs()
        XCTAssertEqual(a, b, message(), file: file, line: line)
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func assertAccessTrue(_ expression: @autoclosure () async throws -> Bool,
                      _ message: @autoclosure () -> String = "",
                      file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertTrue(value, message(), file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func assertAccessFalse(_ expression: @autoclosure () async throws -> Bool,
                       _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertFalse(value, message(), file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func assertAccessNotNil<T>(_ expression: @autoclosure () async throws -> T?,
                          _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertNotNil(value, message(), file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func assertAccessNil<T>(_ expression: @autoclosure () async throws -> T?,
                       _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertNil(value, message(), file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func assertAccessThrows<T>(_ expression: @autoclosure () async throws -> T,
                          _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line,
                          _ handler: (Error) -> Void = { _ in }) async {
    do { _ = try await expression(); XCTFail("Expected an error. " + message(), file: file, line: line) }
    catch { handler(error) }
}
