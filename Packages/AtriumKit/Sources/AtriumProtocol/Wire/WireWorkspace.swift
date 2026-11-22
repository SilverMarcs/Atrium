import Foundation

public nonisolated struct WireWorkspace: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Home-relative path of the primary folder, for display.
    public var directory: String
    /// Every folder of the project on the host, the primary one first. One
    /// that's a repository's top folder has Source Control.
    public var folders: [String]
    /// The detected or chosen project type's raw value.
    public var projectType: String
    /// Asset name of the detected project type's icon, if any.
    public var projectIcon: String?
    /// Fetch with `HostRequest.icon(key:)`; the key changes whenever the icon does.
    public var customIconKey: String?
    /// Drafts put aside, newest first.
    public var scratchpad: [ScratchpadDraft]
    public var hasRunningCommand: Bool

    /// The project's primary folder on the host, where agents start and
    /// commands run.
    public var path: String { folders.first ?? "" }

    public init(
        id: UUID,
        name: String,
        directory: String,
        folders: [String],
        projectType: String,
        projectIcon: String? = nil,
        customIconKey: String? = nil,
        scratchpad: [ScratchpadDraft],
        hasRunningCommand: Bool
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.folders = folders
        self.projectType = projectType
        self.projectIcon = projectIcon
        self.customIconKey = customIconKey
        self.scratchpad = scratchpad
        self.hasRunningCommand = hasRunningCommand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.lenient(.name, or: "")
        directory = container.lenient(.directory, or: "")
        folders = container.lenient(.folders, or: [])
        projectType = container.lenient(.projectType, or: "")
        projectIcon = container.lenient(.projectIcon, or: nil)
        customIconKey = container.lenient(.customIconKey, or: nil)
        scratchpad = container.lenient(.scratchpad, or: [])
        hasRunningCommand = container.lenient(.hasRunningCommand, or: false)
    }
}
