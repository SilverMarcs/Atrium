import Foundation

public nonisolated struct WireWorkspace: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The project folder on the host.
    public var path: String
    /// Home-relative path of the project folder, for display.
    public var directory: String
    /// The detected or chosen project type's raw value.
    public var projectType: String
    /// Asset name of the detected project type's icon, if any.
    public var projectIcon: String?
    /// Fetch with `HostRequest.icon(key:)`; the key changes whenever the icon does.
    public var customIconKey: String?
    public var scratchpad: String
    public var hasRunningCommand: Bool

    public init(
        id: UUID,
        name: String,
        path: String,
        directory: String,
        projectType: String,
        projectIcon: String? = nil,
        customIconKey: String? = nil,
        scratchpad: String,
        hasRunningCommand: Bool
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.directory = directory
        self.projectType = projectType
        self.projectIcon = projectIcon
        self.customIconKey = customIconKey
        self.scratchpad = scratchpad
        self.hasRunningCommand = hasRunningCommand
    }
}
