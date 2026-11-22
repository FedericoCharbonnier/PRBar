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
        // Los vectores cruzados de la web app y una Mac simulada para su e2e (spec web W.9).
        .executable(name: "prbar-remote-fixture", targets: ["PRBarRemoteFixtureServer"]),
    ],
    dependencies: [
        // Primera y única dependencia externa (spec C.3). Versión exacta: subirla es un cambio explícito.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.2"),
    ],
    targets: [
        // Los tipos `Codable` del protocolo de comandos: solo Foundation (los comparten la app, la CLI y el lado remoto).
        .target(name: "PRBarWire"),
        // Cifrado, framing, protocolo del relay y las máquinas de estado remotas (spec P).
        .target(name: "PRBarRemoteKit", dependencies: ["PRBarWire"]),
        .target(name: "PRBarCore", dependencies: ["PRBarWire"]),
        // El lado Mac del acceso desde el iPhone (spec Q): claves, dispositivos, el servicio, el puente a
        // `CommandDispatcher`, el feed de estado, el buzón y los pushes. Aparte de la app para poder testearlo, y de
        // Core para que `prbar` no cargue CryptoKit ni el protocolo del relay.
        .target(name: "PRBarRemoteMac", dependencies: ["PRBarCore", "PRBarRemoteKit"]),
        .target(name: "PRBarRemoteFixtures", dependencies: ["PRBarCore", "PRBarRemoteKit", "PRBarRemoteMac"]),
        .executableTarget(name: "PRBarRemoteFixtureServer",
                          dependencies: ["PRBarCore", "PRBarRemoteKit", "PRBarRemoteMac", "PRBarRemoteFixtures"]),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore", "PRBarRemoteKit", "PRBarRemoteMac"]),
        .target(name: "PRBarCLIKit", dependencies: [
            "PRBarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "PRBarCLI", dependencies: ["PRBarCLIKit"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore", "PRBarCLIKit", "PRBarRemoteKit", "PRBarRemoteMac",
                                                            "PRBarRemoteFixtures"]),
    ]
)
