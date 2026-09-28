// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileConverter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FileConverter", path: "Sources/FileConverter"),
        .testTarget(name: "FileConverterTests", dependencies: ["FileConverter"], path: "Tests/FileConverterTests"),
    ]
)
