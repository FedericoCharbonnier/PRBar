import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Parsea `arguments` como en la terminal y devuelve el `AppCommand` que mandaría (confirmado).
func parsed(_ arguments: [String], confirmed: Bool = true) throws -> AppCommand {
    let command = try PRBarCommand.parseAsRoot(arguments)
    guard let remote = command as? any RemoteCommand else {
        throw TestFailure(description: "\(arguments) no es un comando remoto")
    }
    return try remote.appCommand(confirmed: confirmed)
}

/// `true` si parsear `arguments` falla (uso inválido → exit 2).
func rejects(_ arguments: [String]) -> Bool {
    (try? PRBarCommand.parseAsRoot(arguments)) == nil
}

enum CLIParsingTests {
    static var cases: [TestCase] {
        [
            TestCase("cli parse: status") {
                try expectEqual(try parsed(["status"]), .status)
                try expectEqual(try parsed(["status", "--json"]), .status)
            },
        ]
    }
}
