// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moodboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Moodboard",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Moodboard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
