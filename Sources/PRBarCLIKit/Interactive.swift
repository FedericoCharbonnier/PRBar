import Darwin
import Foundation
import PRBarCore

public enum Prompt {
    /// `pregunta [y/N]`: solo "y"/"yes" confirma (Return cancela, como en la app).
    public static func confirm(_ question: String) -> Bool {
        FileHandle.standardOutput.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Lee un secreto sin eco (el token de Slack).
    public static func secret(_ prompt: String) -> String? {
        guard let pointer = getpass(prompt) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}

public enum Editor {
    /// Abre `text` en `$VISUAL`/`$EDITOR` (`vi` si no hay) y devuelve lo guardado.
    public static func edit(_ text: String, suffix: String = ".md") throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-\(UUID().uuidString)\(suffix)")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let environment = ProcessInfo.processInfo.environment
        let editor = environment["VISUAL"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(editor) \"$1\"", "prbar-editor", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(.cancelled, "The editor exited with an error; nothing changed.")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }
}

/// Lista con casillas (lógica pura; la dibuja `CheckboxPicker`).
public struct CheckboxList: Equatable {
    public struct Row: Equatable {
        public var label: String
        public var checked: Bool

        public init(label: String, checked: Bool) {
            self.label = label
            self.checked = checked
        }
    }

    public enum Key: Equatable { case up, down, toggle, selectAll, selectNone, edit, done, cancel, other }
    public enum Outcome: Equatable { case keepGoing, edit(Int), done, cancel }

    public var rows: [Row]
    public var cursor = 0

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// ↑↓ (o k/j), espacio, a = todos, n = ninguno, e = editar, ↩ = listo, q/Esc/Ctrl-C = cancelar.
    public static func key(from bytes: [UInt8]) -> Key {
        switch bytes {
        case [0x1B, 0x5B, 0x41], [0x6B]: .up
        case [0x1B, 0x5B, 0x42], [0x6A]: .down
        case [0x20]: .toggle
        case [0x61]: .selectAll
        case [0x6E]: .selectNone
        case [0x65]: .edit
        case [0x0D], [0x0A]: .done
        case [0x71], [0x1B], [0x03]: .cancel
        default: .other
        }
    }

    public mutating func handle(_ key: Key) -> Outcome {
        guard !rows.isEmpty else { return key == .cancel ? .cancel : key == .done ? .done : .keepGoing }
        switch key {
        case .up: cursor = max(cursor - 1, 0)
        case .down: cursor = min(cursor + 1, rows.count - 1)
        case .toggle: rows[cursor].checked.toggle()
        case .selectAll: for index in rows.indices { rows[index].checked = true }
        case .selectNone: for index in rows.indices { rows[index].checked = false }
        case .edit: return .edit(cursor)
        case .done: return .done
        case .cancel: return .cancel
        case .other: break
        }
        return .keepGoing
    }

    public func render(colors: Bool) -> String {
        rows.enumerated().map { index, row in
            let pointer = index == cursor ? "›" : " "
            let line = "\(pointer) [\(row.checked ? "x" : " ")] \(row.label)"
            return colors && index == cursor ? "\u{1B}[1m\(line)\u{1B}[0m" : line
        }.joined(separator: "\n") + "\n"
    }
}

enum RawTerminal {
    private static var original = termios()

    /// Lee teclas sin eco ni búfer de línea mientras corre `body` (Ctrl-C llega como tecla).
    static func withRawMode<T>(_ body: () throws -> T) rethrows -> T {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return try body()
    }

    /// Vuelve al modo normal un rato (para abrir `$EDITOR`).
    static func withCookedMode<T>(_ body: () throws -> T) rethrows -> T {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) }
        return try body()
    }

    static func readKey() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        return count > 0 ? Array(buffer.prefix(count)) : [0x03]
    }
}

public enum CheckboxPicker {
    /// Dibuja `list` y la maneja con el teclado. `onEdit(i)` edita la fila `i` y devuelve su nueva etiqueta.
    /// Devuelve la lista final, o `nil` si se canceló.
    public static func run(title: String, list: CheckboxList, output: Output,
                           onEdit: (Int) throws -> String?) throws -> CheckboxList? {
        var list = list
        var drawn = 0
        output.line(output.paint(title, .dim))
        func draw() {
            if drawn > 0 { output.write("\u{1B}[\(drawn)A\u{1B}[J") }
            output.write(list.render(colors: output.terminal.colors))
            drawn = list.rows.count
        }
        return try RawTerminal.withRawMode {
            draw()
            while true {
                switch list.handle(CheckboxList.key(from: RawTerminal.readKey())) {
                case .keepGoing:
                    draw()
                case .done:
                    return list
                case .cancel:
                    return nil
                case .edit(let index):
                    try RawTerminal.withCookedMode {
                        if let label = try onEdit(index) { list.rows[index].label = label }
                    }
                    drawn = 0
                    draw()
                }
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

enum LocalOpen {
    /// `open` (con `reveal`, `open -R`: lo muestra en Finder).
    static func open(_ target: String, reveal: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (reveal ? ["-R"] : []) + [target]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CommandFailure(.failed, "Couldn’t open \(target).") }
    }
}
