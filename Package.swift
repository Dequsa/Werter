// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileConverter",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Google's libwebp; macOS can read WebP but has no encoder.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "FileConverter",
            dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")],
            path: "Sources/FileConverter"
        ),
        .testTarget(name: "FileConverterTests", dependencies: ["FileConverter"], path: "Tests/FileConverterTests"),
    ]
)
