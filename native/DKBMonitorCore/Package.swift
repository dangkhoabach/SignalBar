// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DKBMonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DKBMonitorCore", targets: ["DKBMonitorCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "DKBMonitorCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "DKBMonitorCoreTests", dependencies: ["DKBMonitorCore"]),
    ]
)
