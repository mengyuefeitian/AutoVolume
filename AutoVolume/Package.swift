// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutoVolume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutoVolumeShared", targets: ["AutoVolumeShared"]),
        .executable(name: "AutoVolumeAgent", targets: ["AutoVolumeAgent"]),
        .executable(name: "AutoVolumeApp", targets: ["AutoVolumeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "AutoVolumeShared"),
        .executableTarget(name: "AutoVolumeAgent", dependencies: ["AutoVolumeShared"]),
        .executableTarget(
            name: "AutoVolumeApp",
            dependencies: [
                "AutoVolumeShared",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(name: "AutoVolumeSharedTests", dependencies: ["AutoVolumeShared"]),
        .testTarget(name: "AutoVolumeAppTests", dependencies: ["AutoVolumeApp", "AutoVolumeShared"])
    ]
)
