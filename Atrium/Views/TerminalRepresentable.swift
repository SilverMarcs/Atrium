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
        private var pollTasks: [UUID: Task<Void, Never>] = [:]

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

            pollTasks[tab.id]?.cancel()
            pollTasks[tab.id] = Task { [weak self, weak tab] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let tab else { break }

                    guard let pid = tab.localProcessTerminalView?.process.shellPid, pid > 0 else { continue }

                    var pathInfo = proc_vnodepathinfo()
                    let size = MemoryLayout<proc_vnodepathinfo>.size
                    let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
                    if result == size {
                        let liveDir = withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
                            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                                String(cString: $0)
                            }
                        }
                        if !liveDir.isEmpty, liveDir != tab.currentDirectory {
                            tab.currentDirectory = liveDir
                        }
                    }

                    let fg = tab.childProcesses().first?.name
                    if tab.foregroundProcessName != fg {
                        tab.foregroundProcessName = fg
                    }
                }
                self?.pollTasks[tab?.id ?? UUID()] = nil
            }

            return tv
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {}

        private func resolvedWorkingDirectoryPath(from directory: String?) -> String? {
            guard let directory, !directory.isEmpty else { return nil }

            if let url = URL(string: directory), url.isFileURL {
                return url.path(percentEncoded: false)
            }

            return directory
        }
    }
}
