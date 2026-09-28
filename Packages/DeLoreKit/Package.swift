// swift-tools-version:5.9
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "DeLoreKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DeLoreCore", targets: ["DeLoreCore"]),
        .library(name: "DeLoreFakes", targets: ["DeLoreFakes"])
    ],
    targets: [
        .target(name: "DeLoreCore", swiftSettings: strictConcurrency),
        .target(name: "DeLoreFakes", dependencies: ["DeLoreCore"], swiftSettings: strictConcurrency),
        .testTarget(
            name: "DeLoreCoreTests",
            dependencies: ["DeLoreCore", "DeLoreFakes"],
            swiftSettings: strictConcurrency
        )
    ]
)
