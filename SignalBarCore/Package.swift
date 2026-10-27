// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SignalBarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SignalBarCore", targets: ["SignalBarCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // Citadel and the SSH stack below it sit directly on the credential
        // and host-key path, so both are pinned to the exact revisions that
        // were reviewed rather than a range. `swift-nio-ssh` in particular
        // resolves to a personal fork (see below): an open range there means
        // `swift package update` takes whatever one account has pushed since,
        // with no review step. Bumping either is a deliberate edit that comes
        // with re-reading the diff — especially around key exchange and host
        // key validation.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        // Same packages Citadel itself depends on (Wellz26's swift-nio-ssh fork,
        // per Citadel's own Package.swift) — declared directly here too so
        // SSHCommandRunner.swift can `import NIO`/`NIOSSH`/`Crypto` for the
        // TOFU host-key-pinning validator.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.6"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "SignalBarCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "SignalBarCoreTests", dependencies: ["SignalBarCore"]),
    ]
)
