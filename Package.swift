// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonoMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SonoMac",
            path: "Sources/SonoMac"
        )
    ]
)
