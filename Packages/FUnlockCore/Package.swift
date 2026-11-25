// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FUnlockCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FUnlockCore", targets: ["FUnlockCore"])
    ],
    targets: [
        .target(
            name: "FUnlockCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "FUnlockCoreTests",
            dependencies: ["FUnlockCore"]
        )
    ]
)