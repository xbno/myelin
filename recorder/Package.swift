// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "recorder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "recorder",
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
