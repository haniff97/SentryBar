// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SystemMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SystemMonitor",
            path: "Sources/SystemMonitor"
        ),
        .executableTarget(
            name: "FanHelper",
            path: "Sources/FanHelper"
        )
    ]
)
