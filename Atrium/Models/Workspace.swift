import SwiftUI

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

    @ObservationIgnored
    weak var store: WorkspaceStore?

    @ObservationIgnored
    var inspectorState = InspectorViewState()

    @ObservationIgnored
    var editorPanel = EditorPanel()

    var url: URL {
        URL(fileURLWithPath: directory)
    }

    /// The directory the whole inspector (files, search, git) should reflect. When
    /// the repository containing the workspace folder itself has an active linked
    /// worktree, everything follows it; worktrees of repos merely nested under the
    /// folder stay scoped to the git inspector and don't move the workspace.
    var effectiveURL: URL {
        let workspaceRoot = url.standardizedFileURL.resolvingSymlinksInPath()
        for (repositoryURL, worktreeURL) in inspectorState.git.worktreeOverrides
        where repositoryURL == workspaceRoot || repositoryURL.isAncestor(of: workspaceRoot) {
            if FileManager.default.fileExists(atPath: worktreeURL.path) {
                return worktreeURL
            }
        }
        return url
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
            .appending(path: "Atrium/TaskWorkspace", directoryHint: .isDirectory)
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
        // A new URL refreshes image views even when replacing an image of the same type.
        let filename = "\(id.uuidString)-\(UUID().uuidString).\(safeExt)"
        let dest = dir.appending(path: filename)
        try fm.copyItem(at: sourceURL, to: dest)
        let prior = customIconFilename
        customIconFilename = filename
        if let prior {
            try? fm.removeItem(at: dir.appending(path: prior))
        }
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
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, directory, projectTypeRaw, scratchPad, isArchived
        case customIconFilename
        case commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.directory = try c.decode(String.self, forKey: .directory)
        let rawProjectType = try c.decodeIfPresent(String.self, forKey: .projectTypeRaw) ?? ProjectType.unknown.rawValue
        // Legacy: "xcode" was folded into "swiftPackage" (now displayed as "Swift")
        // since Xcode projects are just one flavor of Swift project.
        self.projectTypeRaw = rawProjectType == "xcode" ? ProjectType.swiftPackage.rawValue : rawProjectType
        self.scratchPad = try c.decodeIfPresent(String.self, forKey: .scratchPad) ?? ""
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.customIconFilename = try c.decodeIfPresent(String.self, forKey: .customIconFilename)
        self.commands = try c.decodeIfPresent([Terminal].self, forKey: .commands) ?? []
        for cmd in commands { cmd.workspace = self }
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

    func moveCommands(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
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

    /// Selects the command in the inspector and sends its `runScript`, starting its
    /// shell first if needed. A freshly started shell gets a moment to reach its
    /// prompt so the script isn't typed into its startup.
    func runCommand(_ entry: Terminal) {
        inspectorState.selectedCommand = entry
        let needsSpawn = entry.localProcessTerminalView == nil
        entry.ensureProcess()
        Task { @MainActor in
            if needsSpawn {
                try? await Task.sleep(for: .milliseconds(300))
            }
            entry.run()
        }
    }
}
