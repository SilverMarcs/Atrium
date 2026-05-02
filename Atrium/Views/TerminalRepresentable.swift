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
            let shellName = "-" + shellBasename
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let startingDirectory = resolvedWorkingDirectoryPath(from: tab.workspace?.directory) ?? home
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            if shellBasename == "zsh", let zdotdir = ShellIntegration.zdotdir() {
                env["ZDOTDIR"] = zdotdir
            }

            let environment = env.map { "\($0.key)=\($0.value)" }

            tv.processDelegate = self

            tv.startProcess(
                executable: shell,
                args: [],
                environment: environment,
                execName: shellName,
                currentDirectory: startingDirectory
            )

            return tv
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        /// Driven by the `preexec`/`precmd` hooks in `ShellIntegration` — the
        /// shell sets the title to the running command on `preexec` and clears
        /// it on `precmd`, giving us instant, accurate run-state without any
        /// kernel polling.
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard let entry = viewMap[ObjectIdentifier(source)] else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let newValue = trimmed.isEmpty ? nil : trimmed
            if entry.tab.foregroundProcessName != newValue {
                entry.tab.foregroundProcessName = newValue
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard let local = source as? LocalProcessTerminalView,
                  let entry = viewMap[ObjectIdentifier(local)] else { return }
            entry.tab.foregroundProcessName = nil
            viewMap.removeValue(forKey: ObjectIdentifier(local))
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
