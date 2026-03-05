// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "opta",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "opta",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
