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
        )
    ]
)
