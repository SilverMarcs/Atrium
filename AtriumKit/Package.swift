// swift-tools-version: 6.2
import PackageDescription

// Apple platforms use CryptoKit and Network. On Linux, swift-crypto and SwiftNIO
// stand in for them; they're declared for every platform, so a Mac can build
// the Linux command-line client with the static Linux SDK, but only Linux builds them.
let onLinux = TargetDependencyCondition.when(platforms: [.linux])
let platformPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
]
let platformProducts: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: onLinux),
    .product(name: "NIOCore", package: "swift-nio", condition: onLinux),
    .product(name: "NIOPosix", package: "swift-nio", condition: onLinux),
    .product(name: "NIOHTTP1", package: "swift-nio", condition: onLinux),
    .product(name: "NIOWebSocket", package: "swift-nio", condition: onLinux),
    .product(name: "NIOFoundationCompat", package: "swift-nio", condition: onLinux),
    .product(name: "NIOSSL", package: "swift-nio-ssl", condition: onLinux),
]

/// Matches the apps: code is main-actor isolated unless it says otherwise.
let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AtriumKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        /// What hosts and clients say to each other, and the encrypted channels they say it over.
        .library(name: "AtriumProtocol", targets: ["AtriumProtocol"]),
        /// Connections to paired hosts and the state each mirrors, for every Atrium client.
        .library(name: "AtriumClient", targets: ["AtriumClient"]),
    ],
    dependencies: platformPackages,
    targets: [
        .target(name: "AtriumProtocol", dependencies: platformProducts, swiftSettings: mainActorByDefault),
        .target(name: "AtriumClient", dependencies: ["AtriumProtocol"], swiftSettings: mainActorByDefault),
        .testTarget(name: "AtriumProtocolTests", dependencies: ["AtriumProtocol"], swiftSettings: mainActorByDefault),
        .testTarget(name: "AtriumClientTests", dependencies: ["AtriumClient"], swiftSettings: mainActorByDefault),
    ]
)
