// swift-tools-version: 6.2
import PackageDescription

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
    targets: [
        .target(name: "AtriumProtocol", swiftSettings: mainActorByDefault),
        .target(name: "AtriumClient", dependencies: ["AtriumProtocol"], swiftSettings: mainActorByDefault),
        .testTarget(name: "AtriumProtocolTests", dependencies: ["AtriumProtocol"], swiftSettings: mainActorByDefault),
        .testTarget(name: "AtriumClientTests", dependencies: ["AtriumClient"], swiftSettings: mainActorByDefault),
    ]
)
