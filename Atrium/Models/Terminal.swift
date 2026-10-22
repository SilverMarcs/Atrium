import AppKit
import Observation
import SwiftTerm

@MainActor
@Observable
final class Terminal: Identifiable, Hashable, Codable {
    var id: UUID

    var title: String
    var currentDirectory: String?

    /// Task sessions follow the terminal font preference; inspector commands is fixed.
    let isTaskTerminal: Bool

    /// When set, this terminal represents a saved "command" the user can run on demand.
    /// Sending the script appends a newline so the shell executes it.
    var runScript: String?

    /// Passed as process arguments, never typed into an interactive shell's input buffer.
    var pendingLaunch: AgentLaunch?
    var hasExited = false

    @ObservationIgnored
    var processDelegate: (any LocalProcessTerminalViewDelegate)?

    @ObservationIgnored
    var onProcessExit: (@MainActor (Int32?) -> Void)?

    /// Whether this saved command is the workspace's default "Run" target (Cmd+R).
    /// Only meaningful for entries in `Workspace.commands`; unused for tasks.
    var isDefault: Bool = false

    /// Exit status reported when the terminal process finishes.
    var lastExitCode: Int32?

    @ObservationIgnored
    weak var workspace: Workspace?

    /// Not encoded; reset per launch.
    var hasBellNotification = false

    var localProcessTerminalView: LocalProcessTerminalView? {
        get { TerminalProcessRegistry.view(for: id) }
        set {
            if let newValue {
                TerminalProcessRegistry.register(newValue, for: id, isTaskTerminal: isTaskTerminal)
            } else {
                TerminalProcessRegistry.remove(for: id)
            }
        }
    }

    init(workspace: Workspace, title: String = "", currentDirectory: String? = nil, runScript: String? = nil, isTaskTerminal: Bool = false) {
        self.id = UUID()
        self.workspace = workspace
        self.title = title
        self.currentDirectory = currentDirectory
        self.runScript = runScript
        self.isTaskTerminal = isTaskTerminal
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, currentDirectory, runScript, isDefault
        // Legacy CommandEntry keys retained so old workspaces.json decodes.
        case name, command
    }

    init(from decoder: Decoder) throws {
        // Only saved inspector commands are persisted.
        self.isTaskTerminal = false
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        if let title = try c.decodeIfPresent(String.self, forKey: .title) {
            self.title = title
        } else if let name = try c.decodeIfPresent(String.self, forKey: .name) {
            self.title = name
        } else {
            self.title = ""
        }
        self.currentDirectory = try c.decodeIfPresent(String.self, forKey: .currentDirectory)
        if let script = try c.decodeIfPresent(String.self, forKey: .runScript) {
            self.runScript = script
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .command) {
            self.runScript = legacy
        } else {
            self.runScript = nil
        }
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(currentDirectory, forKey: .currentDirectory)
        try c.encodeIfPresent(runScript, forKey: .runScript)
        if isDefault { try c.encode(isDefault, forKey: .isDefault) }
    }

    // MARK: - Hashable

    static func == (lhs: Terminal, rhs: Terminal) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Terminal" : trimmed
    }

    var displayDirectory: String {
        guard let currentDirectory else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentDirectory.hasPrefix(home)
            ? "~" + currentDirectory.dropFirst(home.count)
            : currentDirectory
    }

    var hasChildProcess: Bool {
        guard let process = localProcessTerminalView?.process, process.running else { return false }
        // Query the PTY's foreground job on demand; no injected shell hooks.
        let foregroundGroup = tcgetpgrp(process.childfd)
        return foregroundGroup > 0 && foregroundGroup != process.shellPid
    }

    func terminate() {
        // An intentional close must not report a late process exit as task activity.
        onProcessExit = nil
        if let tv = localProcessTerminalView {
            tv.processDelegate = nil
            if tv.process.running {
                for child in childProcesses() {
                    kill(child.pid, SIGHUP)
                }
                tv.terminate()
            }
            tv.removeFromSuperview()
        }
        localProcessTerminalView = nil
        pendingLaunch = nil
        processDelegate = nil
        hasExited = true
        hasBellNotification = false
    }

    func increaseFontSize() {
        guard isTaskTerminal else { return }
        TerminalProcessRegistry.fontSize += 0.5
    }

    func decreaseFontSize() {
        guard isTaskTerminal else { return }
        TerminalProcessRegistry.fontSize -= 0.5
    }

    func resetFontSize() {
        guard isTaskTerminal else { return }
        TerminalProcessRegistry.fontSize = TerminalProcessRegistry.defaultFontSize
    }

    func clearTerminal() {
        guard let tv = localProcessTerminalView else { return }
        tv.resetToInitialState()
        tv.send(txt: "\u{0C}")
    }

    /// Sends `runScript` to the shell if one is configured and the terminal is live.
    /// Caller is responsible for ensuring the view exists first (selecting the terminal
    /// creates it); see `Workspace.runCommand(_:)` for the full flow.
    func run() {
        guard let script = runScript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty,
              let tv = localProcessTerminalView else { return }
        if let dir = workspace?.directory, !dir.isEmpty {
            let escaped = dir
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tv.send(txt: "cd \"\(escaped)\"\n")
        }
        clearTerminal()
        tv.send(txt: script + "\n")
    }

    /// Sends Ctrl+C to interrupt the running foreground process.
    func interrupt() {
        localProcessTerminalView?.send(txt: "\u{03}")
    }

    func childProcesses() -> [(pid: pid_t, name: String)] {
        guard let tv = localProcessTerminalView else { return [] }
        let shellPid = tv.process.shellPid
        guard shellPid > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        sysctl(&mib, 3, nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride
        let procs = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: count)
        defer { procs.deallocate() }
        sysctl(&mib, 3, procs, &size, nil, 0)
        let actualCount = size / MemoryLayout<kinfo_proc>.stride

        var children: [(pid: pid_t, name: String)] = []
        for i in 0..<actualCount {
            if procs[i].kp_eproc.e_ppid == shellPid {
                let name = withUnsafePointer(to: procs[i].kp_proc.p_comm) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                children.append((procs[i].kp_proc.p_pid, name))
            }
        }
        return children
    }
}
