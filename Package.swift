// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicVisualizer",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "MusicVisualizer",
            path: "Sources/MusicVisualizer"
        )
    ]
)
