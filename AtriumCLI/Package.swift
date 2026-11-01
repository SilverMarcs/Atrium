// swift-tools-version: 6.2
import PackageDescription

/// The `atrium` command-line client. Atrium.app builds the same sources into
/// its bundle for the agents it runs; this package builds it on its own, as
/// for Linux.
let package = Package(
    name: "AtriumCLI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "atrium", targets: ["AtriumCLI"]),
    ],
    dependencies: [
        .package(path: "../AtriumKit"),
    ],
    targets: [
        .executableTarget(
            name: "AtriumCLI",
            dependencies: [
                .product(name: "AtriumClient", package: "AtriumKit"),
                .product(name: "AtriumProtocol", package: "AtriumKit"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
