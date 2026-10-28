import Foundation

nonisolated struct WireWorkspace: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// The project folder on the host.
    var path: String
    /// Home-relative path of the project folder, for display.
    var directory: String
    /// The detected or chosen project type's raw value.
    var projectType: String
    /// Asset name of the detected project type's icon, if any.
    var projectIcon: String?
    /// Fetch with `HostRequest.icon(key:)`; the key changes whenever the icon does.
    var customIconKey: String?
    var scratchpad: String
    var hasRunningCommand: Bool
}
