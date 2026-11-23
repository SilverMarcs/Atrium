// swift-tools-version: 6.2
import PackageDescription

/// Matches the Mac app the host was part of: Swift 5 mode, main-actor
/// isolated unless it says otherwise, with approachable concurrency.
let hostSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
]

let package = Package(
    name: "AtriumHost",
    platforms: [.macOS(.v26)],
    products: [
        /// The host every Mac runs: projects, Git, files, agent integrations,
        /// and the server its clients and agents reach it through.
        .library(name: "AtriumHost", targets: ["AtriumHost"]),
    ],
    dependencies: [
        .package(path: "../AtriumKit"),
    ],
    targets: [
        .target(
            name: "AtriumHost",
            dependencies: [
                .product(name: "AtriumProtocol", package: "AtriumKit"),
                // Only for the Mac UI's in-process connection.
                .product(name: "AtriumClient", package: "AtriumKit"),
            ],
            swiftSettings: hostSettings
        ),
    ]
)
