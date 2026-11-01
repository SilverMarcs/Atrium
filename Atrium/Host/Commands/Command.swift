import AppKit
import AtriumProtocol
import Observation

/// A saved command in a project, and its latest run.
///
/// Each run starts the script in the user's shell as a terminal window
/// would, reading the same startup files, on a pseudo-terminal of its own.
/// What it prints is kept as text, and replies and keys are typed into it.
/// The run ends with its script; nothing waits between runs.
@MainActor
@Observable
final class Command: Identifiable, Codable {
    let id: UUID
    var title: String
    /// What a run starts; nil until one is saved.
    var script: String?
    /// Whether this is the project's default command, which Run starts.
    var isDefault = false

    private(set) var output = CommandOutput()
    private(set) var isRunning = false
    /// Where the latest run started: the project folder, or the same folder in
    /// a linked worktree the client that ran it shows.
    private(set) var directory: String?
    private(set) var exitCode: Int32?

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var process: PseudoTerminal?
    /// How many times the running process has been asked to stop.
    @ObservationIgnored private var stopRequests = 0
    /// A run to start once the running one has ended.
    @ObservationIgnored private var pendingRun: (directory: String, script: String?)?

    init(workspace: Workspace, title: String, script: String?) {
        id = UUID()
        self.workspace = workspace
        self.title = title
        self.script = script
    }

    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Command" : title
    }

    // MARK: - Running

    /// Runs the saved script, or `oneOff` in its place, in `directory`. A
    /// running command is interrupted first and runs again once it has ended,
    /// so nothing is typed into a process that's still exiting.
    func run(in directory: String, script oneOff: String? = nil) {
        if process != nil {
            pendingRun = (directory, oneOff)
            process?.write(CommandKey.interrupt.bytes(applicationCursorKeys: false))
            return
        }
        guard let script = (oneOff ?? self.script)?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else { return }
        // Running the saved script starts afresh; a one-off adds to what's there.
        if oneOff == nil { output.clear() }
        output.appendLine("$ " + script)
        self.directory = directory
        exitCode = nil
        stopRequests = 0
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        do {
            // An interactive login shell reads what a terminal window's does,
            // such as the PATH set up in .zshrc.
            let process = try PseudoTerminal(executable: shell, arguments: [shell, "-l", "-i", "-c", script],
                                             environment: environment, directory: directory)
            self.process = process
            isRunning = true
            Task { await follow(process) }
        } catch {
            output.appendLine("Couldn’t start \(shell): \(error.localizedDescription)")
            exitCode = -1
        }
    }

    /// Interrupts the running command. Asked again while it keeps running, it
    /// terminates and then kills it, for programs that ignore Control-C.
    func stop() {
        pendingRun = nil
        guard let process else { return }
        switch stopRequests {
        case 0: process.write(CommandKey.interrupt.bytes(applicationCursorKeys: false))
        case 1: process.signal(SIGTERM)
        default: process.signal(SIGKILL)
        }
        stopRequests += 1
    }

    /// Types a reply and presses Return.
    func reply(_ text: String) -> Bool {
        guard let process else { return false }
        process.write(Array((text + "\r").utf8))
        return true
    }

    func press(_ key: CommandKey) -> Bool {
        guard let process else { return false }
        process.write(key.bytes(applicationCursorKeys: output.usesApplicationCursorKeys))
        return true
    }

    func clearOutput() {
        output.clear()
    }

    /// Hangs up a running command for good, as when it's deleted.
    func terminate() {
        pendingRun = nil
        process?.close()
    }

    private func follow(_ process: PseudoTerminal) async {
        for await event in process.events {
            switch event {
            case .output(let data):
                if output.append(data) { ringBell() }
            case .exit(let status):
                exitCode = status
            }
        }
        guard self.process === process else { return }
        self.process = nil
        isRunning = false
        if let pendingRun {
            self.pendingRun = nil
            run(in: pendingRun.directory, script: pendingRun.script)
        }
    }

    /// A program rings the bell to ask for attention, as when it's waiting on a reply.
    private func ringBell() {
        AppDelegate.bounceDockIcon()
        if !NSApplication.shared.isActive { AppDelegate.showBadge() }
        if let workspace {
            AppDelegate.sendNotification(workspaceID: workspace.id, commandID: id, workspaceName: workspace.name, commandName: displayTitle)
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, isDefault
        case script = "runScript"
        // Names from before commands were renamed, still read from older projects.
        case name, command
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name) ?? ""
        script = try container.decodeIfPresent(String.self, forKey: .script)
            ?? container.decodeIfPresent(String.self, forKey: .command)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(script, forKey: .script)
        if isDefault { try container.encode(isDefault, forKey: .isDefault) }
    }
}

private extension CommandKey {
    /// What the key sends, as a terminal in the program's current mode would.
    func bytes(applicationCursorKeys: Bool) -> [UInt8] {
        let arrow = applicationCursorKeys ? "\u{1B}O" : "\u{1B}["
        let text = switch self {
        case .interrupt: "\u{03}"
        case .endOfInput: "\u{04}"
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .enter: "\r"
        case .up: arrow + "A"
        case .down: arrow + "B"
        case .right: arrow + "C"
        case .left: arrow + "D"
        }
        return Array(text.utf8)
    }
}
