// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pace",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure model, schedule math, fill rule, formatting, providers. No AppKit. Unit-tested.
        .target(
            name: "PaceCore",
            path: "Sources/PaceCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app: status item, popover, settings window.
        .executableTarget(
            name: "PaceApp",
            dependencies: ["PaceCore"],
            path: "Sources/PaceApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PaceCoreTests",
            dependencies: ["PaceCore"],
            path: "Tests/PaceCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
