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
        private var procSources: [UUID: DispatchSourceProcess] = [:]

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

            let environment = env.map { "\($0.key)=\($0.value)" }

            tv.processDelegate = self

            tv.startProcess(
                executable: shell,
                args: [],
                environment: environment,
                execName: shellName,
                currentDirectory: startingDirectory
            )

            startWatching(tab: tab)

            return tv
        }

        /// Watches the shell pid via kqueue (`EVFILT_PROC`) so we react the moment a
        /// child process is forked, exec'd, or exits. Replaces the previous 1s polling loop.
        private func startWatching(tab: Terminal) {
            procSources[tab.id]?.cancel()

            let shellPid = tab.localProcessTerminalView?.process.shellPid ?? 0
            guard shellPid > 0 else { return }

            let source = DispatchSource.makeProcessSource(
                identifier: shellPid,
                eventMask: [.fork, .exec, .exit, .signal],
                queue: .main
            )
            source.setEventHandler { [weak self, weak tab, weak source] in
                guard let tab else { return }
                self?.refresh(tab: tab)
                if let data = source?.data, data.contains(.exit) {
                    source?.cancel()
                }
            }
            source.setCancelHandler { [weak self] in
                self?.procSources[tab.id] = nil
            }
            procSources[tab.id] = source
            source.resume()

            // Prime once so initial state is correct before the first event.
            refresh(tab: tab)
        }

        private func refresh(tab: Terminal) {
            let fg = tab.childProcesses().first?.name
            if tab.foregroundProcessName != fg {
                tab.foregroundProcessName = fg
            }
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard let local = source as? LocalProcessTerminalView,
                  let entry = viewMap[ObjectIdentifier(local)] else { return }
            entry.tab.foregroundProcessName = nil
            procSources[entry.id]?.cancel()
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
