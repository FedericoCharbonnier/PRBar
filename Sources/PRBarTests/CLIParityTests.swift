import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

enum CLIParityTests {
    static let cases: [TestCase] = [
        TestCase("paridad: cada AppCommand lo produce algún comando de la CLI") {
            let produced = Set(CLIRouter.commands.flatMap(\.produces))
            let missing = AppCommand.Name.allCases.filter { !produced.contains($0) }
            try expect(missing.isEmpty, "Sin comando de CLI: \(missing.map(\.rawValue))")
        },
        TestCase("paridad: los ejemplos de la tabla producen lo que dicen") {
            SlackTokenInput.read = { _ in "xoxp-test" }
            for spec in CLIRouter.commands {
                try expect(!spec.samples.isEmpty, "\(spec.path) sin ejemplos")
                var names: Set<AppCommand.Name> = []
                for sample in spec.samples {
                    let command = try PRBarCommand.parseAsRoot(sample)
                    if spec.produces.isEmpty {
                        try expect(command is any LocalCommand, "\(sample) debería ser local")
                        continue
                    }
                    guard let remote = command as? any RemoteCommand else {
                        throw TestFailure(description: "\(sample) no es un comando remoto")
                    }
                    names.insert(try remote.appCommand(confirmed: true).name)
                }
                if !spec.produces.isEmpty {
                    try expectEqual(names, Set(spec.produces))
                }
            }
        },
        TestCase("paridad: la tabla tiene exactamente los subcomandos de prbar") {
            let leaves = Set(CLIRouter.leafPaths())
            let table = Set(CLIRouter.commands.map(\.path))
            try expect(leaves.subtracting(table).isEmpty, "Comandos sin entrada en CLIRouter: \(leaves.subtracting(table).sorted())")
            try expect(table.subtracting(leaves).isEmpty, "Entradas de CLIRouter que no existen: \(table.subtracting(leaves).sorted())")
        },
    ]
}
