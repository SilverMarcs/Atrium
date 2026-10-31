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
    /// Where the client that last ran this command shows the project: its
    /// folder, or the same folder in a linked worktree. Not encoded.
    var runDirectory: String?

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

    @ObservationIgnored
    private var lastOutputAt: ContinuousClock.Instant?

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

    /// Whether a job other than the shell owns the PTY. Only tracked for commands.
    private(set) var isRunning = false

    @ObservationIgnored
    private var jobMonitor: ForegroundJobMonitor?

    /// The job the last stop request targeted and how many times it was asked.
    @ObservationIgnored
    private var stopRequest: (job: pid_t, attempts: Int)?

    /// Set by `restart()` to run the script once the interrupted job has ended.
    @ObservationIgnored
    private var runsWhenIdle = false

    /// Starts tracking the shell's foreground job; call once its process is launched.
    func trackForegroundJob(in view: AppTerminalView) {
        jobMonitor?.cancel()
        let monitor = ForegroundJobMonitor(process: view.process) { [weak self] job in
            self?.foregroundJobChanged(to: job)
        }
        view.onOutput = { [weak monitor] in monitor?.refresh() }
        jobMonitor = monitor
    }

    private func foregroundJobChanged(to job: pid_t?) {
        isRunning = job != nil
        if stopRequest?.job != job {
            stopRequest = nil
        }
        if job == nil, runsWhenIdle {
            runsWhenIdle = false
            workspace?.runCommand(self)
        }
    }

    private func stopTrackingForegroundJob() {
        jobMonitor?.cancel()
        jobMonitor = nil
        isRunning = false
        stopRequest = nil
        runsWhenIdle = false
    }

    /// Records the shell's exit and retires anything tied to its process.
    func processDidExit(exitCode: Int32?) {
        stopTrackingForegroundJob()
        lastExitCode = exitCode
        hasExited = true
        onProcessExit?(exitCode)
    }

    func terminate() {
        // An intentional close must not report a late process exit as task activity.
        onProcessExit = nil
        stopTrackingForegroundJob()
        if let tv = localProcessTerminalView {
            tv.processDelegate = nil
            if tv.process.running {
                for child in ProcessTable.children(of: tv.process.shellPid) {
                    kill(child, SIGHUP)
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

    /// Starts this terminal's shell or agent if it has no process yet. Nothing has to
    /// be on screen; a view hosting the terminal later adopts the running process.
    func ensureProcess() {
        guard localProcessTerminalView == nil else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        _ = TerminalProcessCoordinator.shared.makeTerminalView(for: self, isDark: isDark)
    }

    /// Sends `runScript` to the shell if one is configured and the terminal is live.
    /// See `Workspace.runCommand(_:)`, which starts the shell first.
    func run() {
        guard let script = runScript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty,
              let tv = localProcessTerminalView else { return }
        if let dir = runDirectory ?? workspace?.directory, !dir.isEmpty {
            let escaped = dir
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tv.send(txt: "cd \"\(escaped)\"\n")
        }
        clearTerminal()
        tv.send(txt: script + "\n")
    }

    /// Waits until a newly started task terminal has drawn its interface and gone quiet,
    /// so text typed into it lands in a ready prompt rather than its startup.
    func waitUntilQuiet(for quietPeriod: Duration = .milliseconds(800), timeout: Duration = .seconds(10)) async {
        guard isTaskTerminal, let view = localProcessTerminalView as? AppTerminalView else { return }
        view.onOutput = { [weak self] in self?.lastOutputAt = .now }
        defer { view.onOutput = nil }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let lastOutputAt, clock.now - lastOutputAt >= quietPeriod { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Pastes text into the running program and presses Return, as if the user typed it.
    /// Bracketed paste keeps line breaks inside the prompt instead of submitting early.
    func submit(_ text: String, attaching images: [URL] = []) async {
        guard let view = localProcessTerminalView else { return }
        // Each image's path is pasted on its own, as dropping the file would,
        // so an agent such as Claude Code attaches it as an image.
        for image in images {
            view.send(txt: "\u{1b}[200~" + image.path(percentEncoded: false) + "\u{1b}[201~")
            try? await Task.sleep(for: .milliseconds(150))
            view.send(txt: " ")
        }
        view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        try? await Task.sleep(for: .milliseconds(150))
        view.send(txt: "\r")
    }

    /// Sends Escape, which stops an agent's current turn.
    func sendEscape() {
        localProcessTerminalView?.send(txt: "\u{1b}")
    }

    /// Sends Ctrl+C to interrupt the running foreground process.
    func interrupt() {
        localProcessTerminalView?.send(txt: "\u{03}")
    }

    /// Stops the foreground job, escalating on repeated requests for the same job:
    /// Ctrl+C first, then SIGTERM, then SIGKILL to its process group. Tools such as
    /// `devicectl` trap SIGINT and can linger, so a second press must still work.
    func stop() {
        jobMonitor?.refresh()
        guard let job = jobMonitor?.job else { return }
        let attempts = stopRequest?.job == job ? stopRequest?.attempts ?? 0 : 0
        switch attempts {
        case 0:
            interrupt()
        case 1:
            killpg(job, SIGTERM)
        default:
            killpg(job, SIGKILL)
        }
        stopRequest = (job, attempts + 1)
    }

    /// Interrupts the running job and runs the script again once the shell is back
    /// at its prompt, so the script is never typed into a job that is still exiting.
    func restart() {
        guard isRunning else {
            workspace?.runCommand(self)
            return
        }
        runsWhenIdle = true
        interrupt()
    }
}
