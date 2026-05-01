import Foundation
import Observation

@Observable
final class Workspace: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String

    var directory: String
    var projectTypeRaw: String
    var scratchPad: String
    var isArchived: Bool = false
    private(set) var customIconFilename: String?

    private(set) var commands: [Terminal]
    private(set) var chats: [Chat]

    @ObservationIgnored
    weak var store: WorkspaceStore?

    @ObservationIgnored
    var inspectorState = InspectorViewState()

    @ObservationIgnored
    var editorPanel = EditorPanel()

    var url: URL {
        URL(fileURLWithPath: directory)
    }

    var projectType: ProjectType {
        get { ProjectType(rawValue: projectTypeRaw) ?? .unknown }
        set { projectTypeRaw = newValue.rawValue }
    }

    func detectProjectType() {
        projectType = ProjectType.detect(at: url)
    }

    // MARK: - Custom Icon

    static func iconsDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport
            .appendingPathComponent("Atrium", isDirectory: true)
            .appendingPathComponent("WorkspaceIcons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var customIconURL: URL? {
        guard let name = customIconFilename, !name.isEmpty else { return nil }
        return Self.iconsDirectory().appendingPathComponent(name)
    }

    func setCustomIcon(from sourceURL: URL) throws {
        let fm = FileManager.default
        let dir = Self.iconsDirectory()
        let allowed: Set<String> = ["icns", "png", "jpg", "jpeg"]
        let ext = sourceURL.pathExtension.lowercased()
        let safeExt = allowed.contains(ext) ? ext : "png"
        let filename = "\(id.uuidString).\(safeExt)"
        let dest = dir.appendingPathComponent(filename)

        if let prior = customIconFilename {
            try? fm.removeItem(at: dir.appendingPathComponent(prior))
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: sourceURL, to: dest)
        customIconFilename = filename
        store?.scheduleSave()
    }

    func clearCustomIcon() {
        if let name = customIconFilename {
            let url = Self.iconsDirectory().appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
        customIconFilename = nil
        store?.scheduleSave()
    }

    init(name: String, directory: String) {
        self.id = UUID()
        self.name = name
        self.directory = directory
        self.projectTypeRaw = ProjectType.unknown.rawValue
        self.scratchPad = ""
        self.commands = []
        self.chats = []
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, directory, projectTypeRaw, scratchPad, isArchived
        case customIconFilename
        case commands, chats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.directory = try c.decode(String.self, forKey: .directory)
        self.projectTypeRaw = try c.decodeIfPresent(String.self, forKey: .projectTypeRaw) ?? ProjectType.unknown.rawValue
        self.scratchPad = try c.decodeIfPresent(String.self, forKey: .scratchPad) ?? ""
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.customIconFilename = try c.decodeIfPresent(String.self, forKey: .customIconFilename)
        self.commands = try c.decodeIfPresent([Terminal].self, forKey: .commands) ?? []
        self.chats = try c.decodeIfPresent([Chat].self, forKey: .chats) ?? []
        for cmd in commands { cmd.workspace = self }
        for chat in chats { chat.workspace = self }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(directory, forKey: .directory)
        try c.encode(projectTypeRaw, forKey: .projectTypeRaw)
        try c.encode(scratchPad, forKey: .scratchPad)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(customIconFilename, forKey: .customIconFilename)
        try c.encode(commands, forKey: .commands)
        try c.encode(chats, forKey: .chats)
    }

    // MARK: - Hashable

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Command Management

    @discardableResult
    func addCommand(title: String = "Terminal", runScript: String? = nil) -> Terminal {
        let entry = Terminal(workspace: self, title: title, runScript: runScript)
        commands.append(entry)
        store?.scheduleSave()
        return entry
    }

    var defaultCommand: Terminal? {
        commands.first { $0.isDefault }
    }

    func setDefaultCommand(_ entry: Terminal) {
        for cmd in commands {
            cmd.isDefault = cmd.id == entry.id
        }
        store?.scheduleSave()
    }

    func removeCommand(_ entry: Terminal) {
        if inspectorState.selectedCommand?.id == entry.id {
            inspectorState.selectedCommand = nil
        }
        entry.terminate()
        commands.removeAll { $0.id == entry.id }
        store?.scheduleSave()
    }

    var hasRunningTerminals: Bool {
        commands.contains { $0.localProcessTerminalView != nil }
    }

    var hasActiveChildProcess: Bool {
        commands.contains { $0.hasChildProcess }
    }

    func killAllRunningTerminals() {
        for cmd in commands {
            cmd.terminate()
        }
    }

    func removeAllCommands() {
        inspectorState.selectedCommand = nil
        for cmd in commands {
            cmd.terminate()
        }
        commands.removeAll()
        store?.scheduleSave()
    }

    /// Selects the command in the inspector and sends its `runScript`.
    /// If the terminal view hasn't been created yet, switches to the Commands
    /// tab so the view renders and spawns the shell; otherwise runs in place
    /// without disturbing the user's current tab.
    func runCommand(_ entry: Terminal) {
        inspectorState.selectedCommand = entry
        let needsSpawn = entry.localProcessTerminalView == nil
        if needsSpawn {
            inspectorState.selectedTab = .commands
        }
        Task { @MainActor in
            if needsSpawn {
                try? await Task.sleep(for: .milliseconds(300))
            }
            entry.run()
        }
    }

    // MARK: - Chat Management

    func appendChat(_ chat: Chat) {
        chat.workspace = self
        chats.append(chat)
        store?.scheduleSave()
    }

    @discardableResult
    func addChat(title: String = "New Chat", provider: AgentProvider = .codex, permissionMode: PermissionMode = .bypassPermissions) -> Chat {
        for existing in chats { existing.sortOrder += 1 }
        let chat = Chat(
            title: title,
            provider: provider,
            permissionMode: permissionMode,
            sortOrder: 0
        )
        chat.workspace = self
        chats.append(chat)
        store?.scheduleSave()
        return chat
    }

    func removeChat(_ chat: Chat) {
        chat.disconnect()
        chats.removeAll { $0.id == chat.id }
        store?.scheduleSave()
    }

    func reorderChats(_ sortedChats: [Chat]) {
        for (i, chat) in sortedChats.enumerated() {
            chat.sortOrder = i
        }
        store?.scheduleSave()
    }

    var hasActiveChats: Bool {
        chats.contains { $0.isActive }
    }

    var connectedChatCount: Int {
        chats.lazy.filter { !$0.isArchived && $0.isActive }.count
    }

    func disconnectAllActiveChats() {
        for chat in chats where chat.isActive {
            chat.disconnect()
        }
    }
}
