import Foundation

nonisolated struct WireWorkspace: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Home-relative path of the project folder.
    var directory: String
    /// Asset name of the detected project type's icon, if any.
    var projectIcon: String?
    /// Fetch with `CompanionRequest.icon(key:)`; the key changes whenever the icon does.
    var customIconKey: String?
    var scratchpad: String
    var hasRunningCommand: Bool
}
