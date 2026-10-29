// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AtriumCLI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "atrium", targets: ["AtriumCLI"]),
    ],
    dependencies: [
        .package(path: "../AtriumKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "AtriumCLI",
            dependencies: [
                .product(name: "AtriumClient", package: "AtriumKit"),
                .product(name: "AtriumProtocol", package: "AtriumKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AtriumCLITests", dependencies: ["AtriumCLI"]),
    ]
)
