// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moodboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Moodboard",
            path: "Sources/Moodboard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
