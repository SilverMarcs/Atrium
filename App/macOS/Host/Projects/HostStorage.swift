import Foundation

/// Where the host keeps its data in Application Support. A build with its own
/// bundle identifier, such as a second development host, keeps its own.
nonisolated enum HostStorage {
    static let directory = HostProtocol.applicationSupportFolder(
        appBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.SilverMarcs.Atrium"
    )
}
