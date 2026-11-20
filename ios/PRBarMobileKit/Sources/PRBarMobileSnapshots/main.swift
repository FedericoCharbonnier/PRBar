import AppKit
import PRBarMobileCore
import PRBarMobileUI
import SwiftUI

// Renders screens with the design's sample data to PNG (light and dark), for visual checks without a simulator.
// Usage: swift run PRBarMobileSnapshots [output-dir]   (default: ../snapshots, i.e. ios/snapshots, git-ignored)

@MainActor
func render<V: View>(_ name: String, _ view: V, to directory: URL, height: CGFloat? = nil) {
    for scheme in [ColorScheme.light, .dark] {
        let content = view
            .frame(width: Metrics.phoneWidth, height: height, alignment: .top)
            .background(Tokens.bg)
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: Metrics.phoneWidth, height: height)
        guard let image = renderer.cgImage else {
            print("could not render \(name)")
            continue
        }
        let url = directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}

@MainActor
func main() {
    let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../snapshots")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (name, view, height) in Snapshots.all() {
        render(name, view, to: output, height: height)
    }
}

MainActor.assumeIsolated { main() }
