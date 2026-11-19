import AppKit
import PRBarCore

/// `PRBar --snapshots <dir> [--appearance light|dark|both]` renders the UI with sample data into PNGs and exits
/// (see `SnapshotMode`), without creating the real `AppModel`. Any other launch is the menu bar app.
@main
enum EntryPoint {
    @MainActor
    static func main() {
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
