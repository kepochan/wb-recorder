// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Sources/RecorderCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            path: "Tests/RecorderCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
