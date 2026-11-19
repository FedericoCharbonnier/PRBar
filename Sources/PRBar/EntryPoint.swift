import AppKit
import PRBarCore

/// `PRBar --version` prints `PRBar X.Y.Z` and exits. `PRBar --snapshots <dir> [--appearance light|dark|both]` renders
/// the UI with sample data into PNGs and exits (see `SnapshotMode`), without creating the real `AppModel`. Any other
/// launch is the menu bar app.
@main
enum EntryPoint {
    @MainActor
    static func main() {
        // `PRBar --version`: imprime la versión y sale, sin abrir la app (lo usa el actualizador para verificar el
        // `.app` recién compilado).
        if AppVersion.isVersionRequest(CommandLine.arguments) {
            print(AppVersion.versionLine(AppVersion.current()))
            exit(0)
        }
        switch SnapshotOptions.parse(CommandLine.arguments) {
        case .none:
            PRBarApp.main()
        case .some(.success(let options)):
            SnapshotMode.run(options)
        case .some(.failure(let error)):
            FileHandle.standardError.write(Data("\(error.message)\n\(SnapshotOptions.usage)\n".utf8))
            exit(2)
        }
    }
}
