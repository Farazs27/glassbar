// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlassBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "GlassBar",
            path: "Sources/GlassBar",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
