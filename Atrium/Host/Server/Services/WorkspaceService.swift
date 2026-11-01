import AtriumProtocol
import Foundation

/// Changes a host's projects and their saved commands for clients. Adding
/// and removing projects and choosing icons from files stay with the host.
@MainActor
struct WorkspaceService {
    let workspaces: WorkspaceStore

    func add(path: String) -> HostReply {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(message: "That folder no longer exists.")
        }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        if let existing = workspaces.workspaces.first(where: { $0.url.standardizedFileURL == url }) {
            return .workspace(id: existing.id)
        }
        let workspace = Workspace(name: url.lastPathComponent, directory: url.path(percentEncoded: false))
        workspace.detectProjectType()
        workspaces.addWorkspace(workspace)
        return .workspace(id: workspace.id)
    }

    func perform(_ action: WorkspaceAction, on workspace: Workspace, isLocal: Bool) -> HostReply {
        defer { workspaces.scheduleSave() }
        switch action {
        case .rename(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.name = name.isEmpty ? workspace.url.lastPathComponent : name
        case .setScratchpad(let text):
            workspace.scratchPad = text
        case .setProjectType(let raw):
            workspace.projectTypeRaw = ProjectType(rawValue: raw)?.rawValue ?? ProjectType.unknown.rawValue
        case .detectProjectType:
            workspace.detectProjectType()
        case .setIcon(let path):
            guard isLocal else { return .hostOnly }
            do {
                try workspace.setCustomIcon(from: URL(filePath: path))
                if workspace.projectType == .none { workspace.detectProjectType() }
            } catch {
                return .failed(message: error.localizedDescription)
            }
        case .clearIcon:
            workspace.clearCustomIcon()
        case .move(let index):
            guard let source = workspaces.workspaces.firstIndex(of: workspace) else { break }
            let destination = min(max(index, 0), workspaces.workspaces.count)
            workspaces.moveWorkspaces(from: IndexSet(integer: source), to: destination > source ? destination + 1 : destination)
        case .remove:
            guard isLocal else { return .hostOnly }
            workspaces.deleteWorkspace(workspace)
        case .addCommand(let title, let script):
            return .command(id: workspace.addCommand(title: title, script: script).id)
        }
        return .done
    }

    func perform(_ action: CommandAction, on command: Command, in workspace: Workspace) -> HostReply {
        switch action {
        case .run(let directory, let script):
            guard WorkspaceAccess(directory: workspace.directory).allows(directory) else {
                return .failed(message: "That folder isn’t part of this project.")
            }
            command.run(in: directory, script: script)
        case .stop:
            command.stop()
        case .input(let text):
            guard command.reply(text) else { return .notRunning }
        case .key(let key):
            guard command.press(key) else { return .notRunning }
        case .clear:
            command.clearOutput()
        case .update(let title, let script):
            command.title = title
            command.script = script?.isEmpty == false ? script : nil
            workspaces.scheduleSave()
        case .setDefault:
            workspace.setDefaultCommand(command)
        case .move(let index):
            guard let source = workspace.commands.firstIndex(where: { $0.id == command.id }) else { break }
            let destination = min(max(index, 0), workspace.commands.count)
            workspace.moveCommands(from: IndexSet(integer: source), to: destination > source ? destination + 1 : destination)
        case .remove:
            workspace.removeCommand(command)
        }
        return .done
    }
}

private extension HostReply {
    static let notRunning = HostReply.failed(message: "This command has finished. Run it again to reply.")
}
