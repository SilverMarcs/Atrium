import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#endif

@Observable
final class Command: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String

    /// Shell script run by `run()`. Executed via `/bin/zsh -c <script>` with
    /// the workspace directory as cwd. Nil/empty means the command is a
    /// placeholder until the user edits in a script.
    var runScript: String?

    /// Whether this command is the workspace's default "Run" target (Cmd+R).
    var isDefault: Bool = false

    private(set) var state: CommandState = .idle
    var isRunning: Bool { state.isRunning }

    @ObservationIgnored
    weak var workspace: Workspace?

    @ObservationIgnored
    let output = CommandOutput()

    @ObservationIgnored
    private var process: Process?

    @ObservationIgnored
    private var stdinPipe: Pipe?

    init(workspace: Workspace, title: String = "Terminal", runScript: String? = nil) {
        self.id = UUID()
        self.workspace = workspace
        self.title = title
        self.runScript = runScript
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, runScript, isDefault
        // Legacy keys retained so workspaces saved before the rename still decode.
        case name, command
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        if let title = try c.decodeIfPresent(String.self, forKey: .title) {
            self.title = title
        } else if let name = try c.decodeIfPresent(String.self, forKey: .name) {
            self.title = name
        } else {
            self.title = "Terminal"
        }
        if let script = try c.decodeIfPresent(String.self, forKey: .runScript) {
            self.runScript = script
        } else {
            self.runScript = try c.decodeIfPresent(String.self, forKey: .command)
        }
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(runScript, forKey: .runScript)
        if isDefault { try c.encode(isDefault, forKey: .isDefault) }
    }

    static func == (lhs: Command, rhs: Command) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Lifecycle

    func run() {
        guard let script = runScript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else { return }

        if isRunning { terminate() }

        output.clear()
        CommandRunner.spawn(self, script: script)
    }

    func terminate() {
        guard let p = process, p.isRunning else { return }
        // SIGTERM first; Process.terminate() also sends SIGTERM but we want
        // to fall back to SIGKILL if the process ignores it.
        kill(p.processIdentifier, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak p] in
            if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func interrupt() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGINT)
    }

    func clearOutput() {
        output.clear()
    }

    /// Sends raw text to the running process's stdin. Caller is responsible
    /// for any trailing newline (Tier A doesn't run a PTY, so most programs
    /// won't see typed characters until a `\n` flushes the line).
    func sendInput(_ text: String) {
        guard let pipe = stdinPipe, isRunning else { return }
        if let data = text.data(using: .utf8) {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: - Internal hooks for CommandRunner

    @ObservationIgnored
    var _processBox: Process? {
        get { process }
        set { process = newValue }
    }

    @ObservationIgnored
    var _stdinBox: Pipe? {
        get { stdinPipe }
        set { stdinPipe = newValue }
    }

    func _setState(_ newState: CommandState) {
        state = newState
    }
}
