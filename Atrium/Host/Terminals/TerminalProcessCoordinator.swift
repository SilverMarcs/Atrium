import AppKit
import SwiftTerm

/// Starts terminal processes and receives their callbacks. It is independent of
/// any view so a process can start before, or without, appearing on screen, as
/// when a remote client runs a saved command.
final class TerminalProcessCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalProcessCoordinator()

    /// Process delegates do not retain the Terminal model.
    private final class WeakTerminal {
        weak var value: Terminal?
        init(_ value: Terminal) { self.value = value }
    }

    /// Opens a link clicked in a terminal when it names a file in the
    /// terminal's project, returning false to leave it to the system.
    var openFileLink: (@MainActor (String, Terminal) async -> Bool)?

    /// Keep native directory reports for resolving repository file links.
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        guard let directory,
              let local = source as? LocalProcessTerminalView,
              let terminal = viewMap[ObjectIdentifier(local)]?.value else { return }
        let path: String
        if let url = URL(string: directory), url.isFileURL {
            path = url.path(percentEncoded: false)
        } else {
            path = directory
        }
        guard !path.isEmpty else { return }
        Task { @MainActor in
            if terminal.currentDirectory != path {
                terminal.currentDirectory = path
            }
        }
    }

    private var viewMap: [ObjectIdentifier: WeakTerminal] = [:]

    func register(_ view: LocalProcessTerminalView, for terminal: Terminal) {
        viewMap[ObjectIdentifier(view)] = WeakTerminal(terminal)
    }

    func makeTerminalView(for terminal: Terminal, isDark: Bool) -> LocalProcessTerminalView {
        let tv = AppTerminalView(frame: .zero)
        tv.prepareProcessResponses()
        // Install colors and theme reporting before any shell, agent, or command starts.
        tv.applyAppearance(isDark: isDark)
        // Agent attention comes from provider state, so discard their bells.
        tv.bellStyle = terminal.isTaskTerminal ? .none : .sound
        tv.setCursorStyle(.steadyBlock)
        tv.changeScrollback(TerminalProcessRegistry.scrollback)
        let fontSize = terminal.isTaskTerminal ? TerminalProcessRegistry.fontSize : TerminalProcessRegistry.commandFontSize
        tv.font = NSFont(descriptor: tv.font.fontDescriptor, size: fontSize) ?? tv.font
        // The local and remote presentation hosts enable rendering only while
        // visible. A process started in the background needs no GPU resources.
        terminal.localProcessTerminalView = tv
        terminal.processDelegate = self
        terminal.hasExited = false
        register(tv, for: terminal)

        let launch = terminal.pendingLaunch
        let shell = launch == nil ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : IntegrationProcess.shell
        let shellBasename = (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let startingDirectory = resolvedWorkingDirectoryPath(from: terminal.currentDirectory)
            ?? resolvedWorkingDirectoryPath(from: terminal.workspace?.directory)
            ?? home

        let arguments = launch.map {
            IntegrationProcess.shellArguments(command: $0.executable, arguments: $0.arguments)
        } ?? []
        var env = launch == nil ? ProcessInfo.processInfo.environment : IntegrationProcess.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let environment = env.map { "\($0.key)=\($0.value)" }
        let execName = launch == nil ? "-" + shellBasename : shellBasename
        tv.processDelegate = self

        tv.startProcess(
            executable: shell,
            args: arguments,
            environment: environment,
            execName: execName,
            currentDirectory: startingDirectory
        )

        terminal.pendingLaunch = nil
        if !terminal.isTaskTerminal {
            terminal.trackForegroundJob(in: tv)
        }

        return tv
    }

    func bell(source: SwiftTerm.TerminalView) {
        guard let local = source as? LocalProcessTerminalView,
              let terminal = viewMap[ObjectIdentifier(local)]?.value,
              !terminal.isTaskTerminal else { return }
        terminal.hasBellNotification = true
        AppDelegate.bounceDockIcon()
        if !NSApplication.shared.isActive {
            AppDelegate.showBadge()
        }
        if let workspaceID = terminal.workspace?.id {
            AppDelegate.sendNotification(
                workspaceID: workspaceID,
                terminalID: terminal.id,
                workspaceName: terminal.workspace?.name,
                terminalName: terminal.displayTitle
            )
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func processFailedToStart(source: SwiftTerm.TerminalView, error: LocalProcessError) {
        // SwiftTerm displays the launch error; retire the app session too.
        processTerminated(source: source, exitCode: nil)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let local = source as? LocalProcessTerminalView,
              let terminal = viewMap[ObjectIdentifier(local)]?.value else { return }
        Task { @MainActor in
            terminal.processDidExit(exitCode: exitCode)
        }
        viewMap.removeValue(forKey: ObjectIdentifier(local))
    }

    /// SwiftTerm reposts link activation (click on an OSC 8 hyperlink or an
    /// implicitly detected URL/path) here. A link that resolves to a file
    /// inside the terminal's project opens in the bottom editor panel — same
    /// as clicking it in the file tree; everything else keeps SwiftTerm's
    /// default NSWorkspace behavior.
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        let terminal = (source as? LocalProcessTerminalView)
            .flatMap { viewMap[ObjectIdentifier($0)]?.value }
        Task { @MainActor in
            if let terminal, await openFileLink?(link, terminal) == true {
                return
            }
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func resolvedWorkingDirectoryPath(from directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }

        if let url = URL(string: directory), url.isFileURL {
            return url.path(percentEncoded: false)
        }

        return directory
    }
}
