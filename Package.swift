// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchHub",
            path: "Sources/NotchHub"
        ),
        .testTarget(
            name: "NotchHubTests",
            dependencies: ["NotchHub"],
            path: "Tests/NotchHubTests"
        ),
    ]
)
