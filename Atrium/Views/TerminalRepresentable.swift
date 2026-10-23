import SwiftUI
import SwiftTerm

/// Hosts a retained terminal process for a task or inspector command.
struct TerminalContainerRepresentable: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let terminal: Terminal
    let appState: AppState

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(frame: .zero)
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        // A retiring host must not recreate a process after its session is closed.
        guard !terminal.hasExited || terminal.localProcessTerminalView != nil else { return }
        let coordinator = context.coordinator
        let terminalView: LocalProcessTerminalView

        if let existing = terminal.localProcessTerminalView {
            terminalView = existing
        } else {
            terminalView = coordinator.createTerminalView(for: terminal, appState: appState, isDark: colorScheme == .dark)
        }

        (terminalView as? AppTerminalView)?.applyAppearance(isDark: colorScheme == .dark)

        if terminalView.processDelegate !== terminal.processDelegate {
            terminalView.processDelegate = terminal.processDelegate
        }

        container.host(terminalView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Process delegates do not retain the Terminal model.
    final class WeakTerminal {
        weak var value: Terminal?
        init(_ value: Terminal) { self.value = value }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
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

        private weak var appState: AppState?

        private var viewMap: [ObjectIdentifier: WeakTerminal] = [:]

        func register(_ view: LocalProcessTerminalView, for terminal: Terminal) {
            viewMap[ObjectIdentifier(view)] = WeakTerminal(terminal)
        }

        func createTerminalView(for terminal: Terminal, appState: AppState, isDark: Bool) -> LocalProcessTerminalView {
            self.appState = appState
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
            try? tv.setUseMetal(true)
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

            return tv
        }

        func bell(source: SwiftTerm.TerminalView) {
            guard let local = source as? LocalProcessTerminalView,
                  let terminal = viewMap[ObjectIdentifier(local)]?.value,
                  !terminal.isTaskTerminal else { return }
            let isSelected = appState?.activeTerminal === terminal
            if !isSelected || source.window == nil {
                terminal.hasBellNotification = true
            }
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
                terminal.lastExitCode = exitCode
                terminal.hasExited = true
                terminal.onProcessExit?(exitCode)
            }
            viewMap.removeValue(forKey: ObjectIdentifier(local))
        }

        /// SwiftTerm reposts link activation (click on an OSC 8 hyperlink or an
        /// implicitly detected URL/path) here. A link that resolves to a file
        /// inside the terminal's workspace opens in the bottom editor panel — same
        /// as clicking it in the file tree; everything else keeps SwiftTerm's
        /// default NSWorkspace behavior.
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            let terminal = (source as? LocalProcessTerminalView)
                .flatMap { viewMap[ObjectIdentifier($0)]?.value }
            Task { @MainActor [weak self] in
                if let self, let terminal, let target = self.workspaceFileTarget(for: link, terminal: terminal) {
                    terminal.workspace?.editorPanel.openFile(target.url, scrollToLine: target.line)
                    return
                }
                if let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        /// Resolves a clicked link to a file inside the terminal's workspace, or nil
        /// if it isn't one. Handles `file:` URLs, absolute, `~/`, and relative
        /// paths (resolved against the terminal's cwd, then the workspace root, so
        /// workspace-relative paths printed by tools resolve even when the
        /// shell's cwd is elsewhere), plus a trailing `:line[:column]` suffix
        /// from compiler-style output.
        private func workspaceFileTarget(for link: String, terminal: Terminal) -> (url: URL, line: Int?)? {
            guard let workspace = terminal.workspace else { return nil }

            let rawPath: String
            if link.hasPrefix("file:") {
                guard let url = URL(string: link), url.isFileURL else { return nil }
                rawPath = url.path(percentEncoded: false)
            } else if link.contains("://") {
                return nil
            } else {
                rawPath = link
            }

            var candidates: [(path: String, line: Int?)] = [(rawPath, nil)]
            if let match = rawPath.wholeMatch(of: /(.+?):(\d+)(?::\d+)?/) {
                candidates.append((String(match.1), Int(match.2)))
            }

            let roots = [workspace.effectiveURL, workspace.url].map { $0.standardizedFileURL.path }
            let cwd = resolvedWorkingDirectoryPath(from: terminal.currentDirectory) ?? workspace.directory
            for (path, line) in candidates {
                let resolved: [URL]
                if path.hasPrefix("/") {
                    resolved = [URL(fileURLWithPath: path)]
                } else if path == "~" || path.hasPrefix("~/") {
                    resolved = [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
                } else {
                    resolved = ([cwd] + roots).map { URL(fileURLWithPath: $0).appending(path: path) }
                }
                for url in resolved.map(\.standardizedFileURL) {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else { continue }
                    guard roots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { continue }
                    return (url, line)
                }
            }
            return nil
        }

        private func resolvedWorkingDirectoryPath(from directory: String?) -> String? {
            guard let directory, !directory.isEmpty else { return nil }

            if let url = URL(string: directory), url.isFileURL {
                return url.path(percentEncoded: false)
            }

            return directory
        }
    }
}
