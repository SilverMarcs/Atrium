import AtriumProtocol
import SwiftUI

@Observable
final class Workspace: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String

    /// The primary folder: agents start here and commands run here.
    private(set) var directory: String
    /// The project's other folders, anywhere on the host. Each one that's a
    /// repository's top folder gets Source Control; the rest show files only.
    private(set) var additionalFolders: [String] = []
    var projectTypeRaw: String
    /// Drafts put aside, newest first.
    private(set) var scratchpad: [ScratchpadEntry] = []
    var isArchived: Bool = false
    private(set) var customIconFilename: String?

    private(set) var commands: [Command]

    @ObservationIgnored
    weak var store: WorkspaceStore?

    var url: URL {
        URL(fileURLWithPath: directory)
    }

    /// Every folder of the project, the primary one first.
    var folders: [String] { [directory] + additionalFolders }

    /// What clients may reach through the project.
    var access: WorkspaceAccess { WorkspaceAccess(folders: folders) }

    /// Replaces the project's folders, the first becoming the primary one.
    func setFolders(_ folders: [String]) {
        guard let primary = folders.first else { return }
        directory = primary
        additionalFolders = Array(folders.dropFirst())
        store?.scheduleSave()
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
        let dir = HostStorage.directory.appending(path: "TaskWorkspace/WorkspaceIcons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    init(name: String, folders: [String]) {
        self.id = UUID()
        self.name = name
        self.directory = folders.first ?? ""
        self.additionalFolders = Array(folders.dropFirst())
        self.projectTypeRaw = ProjectType.unknown.rawValue
        self.commands = []
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, directory, additionalFolders, projectTypeRaw, scratchpad, isArchived
        /// The scratchpad's notes before it held drafts.
        case scratchPad
        case customIconFilename
        case commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.directory = try c.decode(String.self, forKey: .directory)
        self.additionalFolders = try c.decodeIfPresent([String].self, forKey: .additionalFolders) ?? []
        let rawProjectType = try c.decodeIfPresent(String.self, forKey: .projectTypeRaw) ?? ProjectType.unknown.rawValue
        // Legacy: "xcode" was folded into "swiftPackage" (now displayed as "Swift")
        // since Xcode projects are just one flavor of Swift project.
        self.projectTypeRaw = rawProjectType == "xcode" ? ProjectType.swiftPackage.rawValue : rawProjectType
        var scratchpad = try c.decodeIfPresent([ScratchpadEntry].self, forKey: .scratchpad) ?? []
        if let notes = try c.decodeIfPresent(String.self, forKey: .scratchPad),
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scratchpad.append(ScratchpadEntry(text: notes))
        }
        self.scratchpad = scratchpad
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.customIconFilename = try c.decodeIfPresent(String.self, forKey: .customIconFilename)
        self.commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        for cmd in commands { cmd.workspace = self }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(directory, forKey: .directory)
        try c.encode(additionalFolders, forKey: .additionalFolders)
        try c.encode(projectTypeRaw, forKey: .projectTypeRaw)
        try c.encode(scratchpad, forKey: .scratchpad)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(customIconFilename, forKey: .customIconFilename)
        try c.encode(commands, forKey: .commands)
    }

    // MARK: - Scratchpad

    /// The drafts for clients, which fetch their images by file name.
    var scratchpadDrafts: [ScratchpadDraft] {
        scratchpad.map { ScratchpadDraft(id: $0.id, text: $0.text, imageKeys: $0.imageFiles) }
    }

    func addToScratchpad(_ text: String, images: [Data]) throws {
        scratchpad.insert(ScratchpadEntry(text: text, imageFiles: try ScratchpadEntry.save(images)), at: 0)
    }

    func editScratchpadDraft(_ id: UUID, text: String) {
        guard let index = scratchpad.firstIndex(where: { $0.id == id }) else { return }
        scratchpad[index].text = text
    }

    /// Removes a draft, deleting its image files.
    /// - Returns: Its text and images as they were added.
    func removeScratchpadDraft(_ id: UUID) -> (text: String, images: [Data])? {
        guard let index = scratchpad.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = scratchpad.remove(at: index)
        defer { entry.deleteImages() }
        return (entry.text, entry.images())
    }

    // MARK: - Hashable

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Command Management

    func addCommand(title: String, script: String?) -> Command {
        let command = Command(workspace: self, title: title, script: script)
        commands.append(command)
        store?.scheduleSave()
        return command
    }

    func setDefaultCommand(_ entry: Command) {
        for cmd in commands {
            cmd.isDefault = cmd.id == entry.id
        }
        store?.scheduleSave()
    }

    func moveCommands(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
        store?.scheduleSave()
    }

    func removeCommand(_ entry: Command) {
        entry.terminate()
        commands.removeAll { $0.id == entry.id }
        store?.scheduleSave()
    }
}
