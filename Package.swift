// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PRBar", targets: ["PRBar"]),
        // Se instala como `prbar` (Contents/Helpers/prbar): un producto `prbar` chocaría con `PRBar` en .build/
        // porque APFS no distingue mayúsculas.
        .executable(name: "PRBarCLI", targets: ["PRBarCLI"]),
    ],
    dependencies: [
        // Primera y única dependencia externa (spec C.3). Versión exacta: subirla es un cambio explícito.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.2"),
    ],
    targets: [
        .target(name: "PRBarCore"),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore"]),
        .target(name: "PRBarCLIKit", dependencies: [
            "PRBarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "PRBarCLI", dependencies: ["PRBarCLIKit"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore", "PRBarCLIKit"]),
    ]
)
