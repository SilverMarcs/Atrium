import Foundation

nonisolated struct WireWorkspace: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Home-relative path of the primary folder, for display.
    var directory: String
    /// Every folder of the project on the host, the primary one first. One
    /// that's a repository's top folder has Source Control.
    var folders: [String]
    /// The detected or chosen project type's raw value.
    var projectType: String
    /// Asset name of the detected project type's icon, if any.
    var projectIcon: String?
    /// Fetch with `HostRequest.icon(key:)`; the key changes whenever the icon does.
    var customIconKey: String?
    /// Drafts put aside, newest first.
    var scratchpad: [ScratchpadDraft]
    /// How many of the project's saved commands are running.
    var runningCommandCount: Int
    /// Background shell sessions agents are running in the project.
    var backgroundSessions: [WireBackgroundSession]

    /// The project's primary folder on the host, where agents start and
    /// commands run.
    var path: String { folders.first ?? "" }
    /// Saved commands and agent background sessions running, for badges.
    var runningCount: Int { runningCommandCount + backgroundSessions.count }

    init(
        id: UUID,
        name: String,
        directory: String,
        folders: [String],
        projectType: String,
        projectIcon: String? = nil,
        customIconKey: String? = nil,
        scratchpad: [ScratchpadDraft],
        runningCommandCount: Int,
        backgroundSessions: [WireBackgroundSession] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.folders = folders
        self.projectType = projectType
        self.projectIcon = projectIcon
        self.customIconKey = customIconKey
        self.scratchpad = scratchpad
        self.runningCommandCount = runningCommandCount
        self.backgroundSessions = backgroundSessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.lenient(.name, or: "")
        directory = container.lenient(.directory, or: "")
        folders = container.lenient(.folders, or: [])
        projectType = container.lenient(.projectType, or: "")
        projectIcon = container.lenient(.projectIcon, or: nil)
        customIconKey = container.lenient(.customIconKey, or: nil)
        scratchpad = container.lenient(.scratchpad, or: [])
        runningCommandCount = container.lenient(.runningCommandCount, or: 0)
        backgroundSessions = container.lenient(.backgroundSessions, or: [])
    }
}
