// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CTRL",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "CTRL",
            path: "Sources/CTRL",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
