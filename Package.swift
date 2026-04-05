// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "opta",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "opta",
            path: "Sources",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
