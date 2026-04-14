// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeynotePPTX",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/lovetodream/swift-snappy.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "KeynotePPTX",
            dependencies: [
                .product(name: "Snappy", package: "swift-snappy"),
            ],
            path: "Sources/KeynotePPTX"
        ),
    ]
)
