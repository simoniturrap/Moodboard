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
            swiftSettings: [.swiftLanguageMode(.v5)],
            // El `VideoPlayer` de SwiftUI instancia internamente un `AVPlayerView`, que vive en
            // AVKit.framework. El autolink sólo trae `_AVKit_SwiftUI` y AVFoundation, no AVKit entero:
            // sin él, el runtime no resuelve la metadata de `AVPlayerView` y la app crashea al mostrar
            // un video. Enlazar AVKit explícitamente lo arregla.
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
