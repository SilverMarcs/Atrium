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

    private(set) var commands: [Command]

    @ObservationIgnored
    weak var store: WorkspaceStore?

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
        self.commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
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
