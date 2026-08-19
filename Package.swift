// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeRCManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeRCManager",
            path: "Sources/ClaudeRCManager"
        ),
        .testTarget(
            name: "ClaudeRCManagerTests",
            dependencies: ["ClaudeRCManager"],
            path: "Tests/ClaudeRCManagerTests"
        ),
    ]
)
