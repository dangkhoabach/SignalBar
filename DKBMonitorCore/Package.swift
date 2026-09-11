// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DKBMonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DKBMonitorCore", targets: ["DKBMonitorCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
        // Same packages Citadel itself depends on (Wellz26's swift-nio-ssh fork,
        // per Citadel's own Package.swift) — declared directly here too so
        // SSHCommandRunner.swift can `import NIO`/`NIOSSH`/`Crypto` for the
        // TOFU host-key-pinning validator (docs/remote-server-management-plan.md).
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "DKBMonitorCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "DKBMonitorCoreTests", dependencies: ["DKBMonitorCore"]),
    ]
)
