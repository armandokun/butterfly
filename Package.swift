// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Butterfly",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Self-updates from GitHub Releases (armandokun/butterfly).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Butterfly",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Butterfly",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework: Butterfly.app/Contents/Frameworks (copied by scripts/build.sh), or next to the binary in .build (CLI flags).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
