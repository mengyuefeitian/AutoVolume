// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoVolume",
    products: [
        .library(name: "AutoVolumeShared", targets: ["AutoVolumeShared"]),
        .executable(name: "AutoVolumeAgent", targets: ["AutoVolumeAgent"]),
        .executable(name: "AutoVolumeApp", targets: ["AutoVolumeApp"])
    ],
    dependencies: [],
    targets: [
        .target(name: "AutoVolumeShared"),
        .executableTarget(name: "AutoVolumeAgent", dependencies: ["AutoVolumeShared"]),
        .executableTarget(name: "AutoVolumeApp", dependencies: ["AutoVolumeShared"]),
        .testTarget(name: "AutoVolumeSharedTests", dependencies: ["AutoVolumeShared"]),
        .testTarget(name: "AutoVolumeAppTests", dependencies: ["AutoVolumeApp", "AutoVolumeShared"])
    ]
)
