// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "recorder",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "recorder",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Recorder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Embed Info.plist so the system-audio TCC prompt has a usage string.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        // Menu-bar app: a thin SwiftUI supervisor that spawns the `recorder`
        // binary as a child, names meetings from the calendar, and shows state.
        // Keeps the CLI untouched; capture stays in `recorder`.
        .executableTarget(
            name: "LiveRecorderApp",
            path: "Sources/LiveRecorderApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
