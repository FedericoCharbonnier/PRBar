import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, _ body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    if try !condition() {
        throw TestFailure(description: "\(file):\(line) expectation failed. \(message())")
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    file: StaticString = #fileID, line: UInt = #line
) throws {
    let a = try actual()
    let e = try expected()
    if a != e {
        throw TestFailure(description: "\(file):\(line) expected \(e), got \(a)")
    }
}

func expectThrows(
    file: StaticString = #fileID, line: UInt = #line,
    _ body: () async throws -> Void
) async throws -> Error {
    do {
        try await body()
    } catch {
        return error
    }
    throw TestFailure(description: "\(file):\(line) expected an error, none thrown")
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
