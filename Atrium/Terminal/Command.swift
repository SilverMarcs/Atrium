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

    /// In-memory history of scripts the user typed into the inline input bar.
    /// Drives up/down arrow recall in `CommandOutputView`. Not persisted —
    /// lifetime matches the workspace's in-memory `Command` instance.
    @ObservationIgnored
    var inputHistory: [String] = []

    func recordHistory(_ script: String) {
        let trimmed = script.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if inputHistory.last == trimmed { return }
        inputHistory.append(trimmed)
    }

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

    /// Runs the saved script. Clears the output first so each run gets a
    /// fresh view (matches the play-button / Cmd+R UX).
    func run() {
        guard let script = runScript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else { return }
        output.clear()
        spawn(script)
    }

    /// Runs an arbitrary script without touching the saved `runScript` or
    /// clearing prior output. Used by the inline input bar so the entry
    /// behaves like a shell history.
    func runScript(_ script: String) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spawn(trimmed)
    }

    private func spawn(_ script: String) {
        if isRunning { terminate() }
        let raw = workspace?.directory ?? ""
        let dir = raw.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // Ensure the path line starts at a line boundary even when prior
        // program output didn't end in a newline — otherwise the prompt
        // visually merges into the trailing output.
        let leadingNewline = (output.text.isEmpty || output.text.hasSuffix("\n")) ? "" : "\n"
        output.append("\(leadingNewline)\(dir)\n> \(script)\n")
        CommandRunner.spawn(self, script: script)
    }

    func terminate() {
        guard let p = process, p.isRunning else { return }
        // The Process is `/bin/zsh -c <script>`; zsh in non-interactive `-c`
        // mode often doesn't forward signals to its child program, so we
        // signal the whole descendant tree, leaves first.
        let tree = Self.processTree(rootedAt: p.processIdentifier)
        for pid in tree { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak p] in
            guard let p, p.isRunning else { return }
            // Best-effort follow-up: re-walk the tree (some pids may be gone)
            // and SIGKILL anything still alive.
            let stillAlive = Self.processTree(rootedAt: p.processIdentifier)
            for pid in stillAlive { kill(pid, SIGKILL) }
        }
    }

    func interrupt() {
        guard let p = process, p.isRunning else { return }
        let tree = Self.processTree(rootedAt: p.processIdentifier)
        for pid in tree { kill(pid, SIGINT) }
    }

    /// Returns `[leaves..., root]` of the live process subtree using
    /// `pgrep -P` recursively. Leaf-first ordering means a SIGTERM walk
    /// reaches the actual long-running program before its zsh wrapper exits
    /// and orphans it.
    private static func processTree(rootedAt root: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []
        var queue: [pid_t] = [root]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            let kids = directChildren(of: pid)
            descendants.append(contentsOf: kids)
            queue.append(contentsOf: kids)
        }
        return descendants.reversed() + [root]
    }

    private static func directChildren(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: { $0.isNewline }).compactMap { pid_t($0) }
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
