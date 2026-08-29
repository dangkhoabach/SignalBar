// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DKBMonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DKBMonitorCore", targets: ["DKBMonitorCore"])
    ],
    targets: [
        .target(name: "DKBMonitorCore"),
        .testTarget(name: "DKBMonitorCoreTests", dependencies: ["DKBMonitorCore"]),
    ]
)
