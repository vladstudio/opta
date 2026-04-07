// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "opta",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../app-kit"),
    ],
    targets: [
        .executableTarget(
            name: "opta",
            dependencies: [.product(name: "MacAppKit", package: "app-kit")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
