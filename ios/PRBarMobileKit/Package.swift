// swift-tools-version:6.0
import PackageDescription

// The iPhone app's logic and views (plan 19). It builds on macOS 26 too, so the view models, formatting and state tests
// run with `swift test` on the Mac without a simulator, and `swift run PRBarMobileSnapshots` renders screens to PNG.
let package = Package(
    name: "PRBarMobileKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "PRBarMobileKit", targets: ["PRBarMobileCore", "PRBarMobileUI"]),
    ],
    dependencies: [
        .package(name: "PRBar", path: "../.."),
    ],
    targets: [
        // Transport seam, connection, store, cache, keychain, Face ID and one view model per screen.
        .target(name: "PRBarMobileCore", dependencies: [.product(name: "PRBarRemoteKit", package: "PRBar")]),
        // Design tokens, components and screens (SwiftUI).
        .target(name: "PRBarMobileUI", dependencies: ["PRBarMobileCore"]),
        // macOS-only: renders screens with fixtures to PNG for visual checks.
        .executableTarget(name: "PRBarMobileSnapshots", dependencies: ["PRBarMobileUI"]),
        .testTarget(name: "PRBarMobileCoreTests", dependencies: ["PRBarMobileCore"]),
    ]
)
