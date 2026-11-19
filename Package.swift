// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PRBar", targets: ["PRBar"])],
    targets: [
        .target(name: "PRBarCore"),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore"]),
    ]
)
