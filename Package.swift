// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .executable(name: "PRBar", targets: ["PRBar"]),
        // Se instala como `prbar` (Contents/Helpers/prbar): un producto `prbar` chocaría con `PRBar` en .build/
        // porque APFS no distingue mayúsculas.
        .executable(name: "PRBarCLI", targets: ["PRBarCLI"]),
        // La app de iOS (Plan 19) consume este producto como paquete local.
        .library(name: "PRBarRemoteKit", targets: ["PRBarRemoteKit"]),
    ],
    dependencies: [
        // Primera y única dependencia externa (spec C.3). Versión exacta: subirla es un cambio explícito.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.2"),
    ],
    targets: [
        // Los tipos `Codable` del protocolo de comandos: solo Foundation, compilan también para iOS.
        .target(name: "PRBarWire"),
        // Cifrado, framing, protocolo del relay y las máquinas de estado remotas (spec P): también para iOS.
        .target(name: "PRBarRemoteKit", dependencies: ["PRBarWire"]),
        .target(name: "PRBarCore", dependencies: ["PRBarWire"]),
        // El lado Mac del acceso desde el iPhone (spec Q): claves, dispositivos, el servicio, el puente a
        // `CommandDispatcher`, el feed de estado, el buzón y los pushes. Aparte de la app para poder testearlo, y de
        // Core para que `prbar` no cargue CryptoKit ni el protocolo del relay.
        .target(name: "PRBarRemoteMac", dependencies: ["PRBarCore", "PRBarRemoteKit"]),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore", "PRBarRemoteKit", "PRBarRemoteMac"]),
        .target(name: "PRBarCLIKit", dependencies: [
            "PRBarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "PRBarCLI", dependencies: ["PRBarCLIKit"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore", "PRBarCLIKit", "PRBarRemoteKit", "PRBarRemoteMac"]),
    ]
)
