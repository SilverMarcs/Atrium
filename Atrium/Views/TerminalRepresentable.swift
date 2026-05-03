import SwiftUI
import SwiftTerm

/// Displays a single terminal's view inside a SwiftUI hierarchy.
/// The `LocalProcessTerminalView` is retained by `TerminalProcessRegistry` so it
/// survives view rebuilds without being destroyed/recreated.
struct TerminalContainerRepresentable: NSViewRepresentable {
    let tab: Terminal

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let terminalView: LocalProcessTerminalView

        if let existing = tab.localProcessTerminalView {
            terminalView = existing
            coordinator.register(existing, for: tab)
        } else {
            terminalView = coordinator.createTerminalView(for: tab)
        }

        terminalView.processDelegate = coordinator

        // Add to container if not already a subview (never remove — just hide/show)
        if terminalView.superview !== container {
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // Hide all, then show the selected one
        for subview in container.subviews {
            subview.isHidden = (subview !== terminalView)
        }
        terminalView.isHidden = false

        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Weak wrapper so OSC handler closures don't retain the Terminal model.
    private final class WeakTab {
        weak var value: Terminal?
        init(_ value: Terminal) { self.value = value }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        private var viewMap: [ObjectIdentifier: (id: UUID, tab: Terminal)] = [:]

        func register(_ view: LocalProcessTerminalView, for tab: Terminal) {
            viewMap[ObjectIdentifier(view)] = (id: tab.id, tab: tab)
        }

        func createTerminalView(for tab: Terminal) -> LocalProcessTerminalView {
            let tv = LocalProcessTerminalView(frame: .zero)
            tv.configureNativeColors()
            tv.getTerminal().setCursorStyle(.blinkBar)
            tv.font = NSFont(descriptor: tv.font.fontDescriptor, size: TerminalProcessRegistry.fontSize) ?? tv.font
            tab.localProcessTerminalView = tv
            register(tv, for: tab)

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellBasename = (shell as NSString).lastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let startingDirectory = resolvedWorkingDirectoryPath(from: tab.workspace?.directory) ?? home

            let plan = ShellIntegration.plan(forShellPath: shell)

            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            for (k, v) in plan.env { env[k] = v }
            let environment = env.map { "\($0.key)=\($0.value)" }

            // bash --rcfile only takes effect for non-login shells, so when our
            // plan injects rc args we must drop the leading-dash login convention.
            let execName = plan.args.contains("--rcfile") ? shellBasename : "-" + shellBasename

            tv.processDelegate = self

            installSemanticPromptHandler(on: tv, for: tab)

            tv.startProcess(
                executable: shell,
                args: plan.args,
                environment: environment,
                execName: execName,
                currentDirectory: startingDirectory
            )

            return tv
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        /// SwiftTerm calls this for OSC 0/1/2 (window/icon title). Programs like
        /// vim, ssh, and tmux freely overwrite the title, so it is *not* a
        /// reliable signal for whether a command is running — the OSC 133
        /// handler installed in `installSemanticPromptHandler` owns that state.
        /// We intentionally ignore the title for state tracking.
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard let local = source as? LocalProcessTerminalView,
                  let entry = viewMap[ObjectIdentifier(local)] else { return }
            DispatchQueue.main.async {
                entry.tab.foregroundProcessName = nil
            }
            viewMap.removeValue(forKey: ObjectIdentifier(local))
        }

        /// Registers an OSC 133 (FinalTerm semantic prompt) handler on the
        /// underlying `Terminal`. The shell-integration scripts emit:
        ///   - `\e]133;C;<command>\a` when a foreground command starts
        ///   - `\e]133;D;<exit>\a`    when it finishes
        /// This is the authoritative signal driving `foregroundProcessName`
        /// and `lastExitCode`, regardless of what programs do with the title.
        func installSemanticPromptHandler(on view: LocalProcessTerminalView, for tab: Terminal) {
            let weakTab = WeakTab(tab)
            view.getTerminal().registerOscHandler(code: 133) { data in
                let payload = String(bytes: data, encoding: .utf8) ?? ""
                // Payload format: "<verb>" or "<verb>;<arg>"
                let verb: String
                let arg: String
                if let semi = payload.firstIndex(of: ";") {
                    verb = String(payload[..<semi])
                    arg = String(payload[payload.index(after: semi)...])
                } else {
                    verb = payload
                    arg = ""
                }
                switch verb {
                case "C":
                    let name = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = name.isEmpty ? "(running)" : name
                    DispatchQueue.main.async {
                        guard let tab = weakTab.value else { return }
                        if tab.foregroundProcessName != value {
                            tab.foregroundProcessName = value
                        }
                    }
                case "D":
                    let exit = Int32(arg.trimmingCharacters(in: .whitespacesAndNewlines))
                    DispatchQueue.main.async {
                        guard let tab = weakTab.value else { return }
                        tab.foregroundProcessName = nil
                        tab.lastExitCode = exit
                    }
                default:
                    break  // 133;A (prompt-start) and 133;B (prompt-end) ignored
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
}
