import SwiftUI
import SwiftTerm

/// Hosts a retained terminal process for a task or inspector command.
struct TerminalContainerRepresentable: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let terminal: Terminal
    let appState: AppState
    var acceptsInputFocus = true

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(frame: .zero)
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        container.acceptsInputFocus = acceptsInputFocus
        // A retiring host must not recreate a process after its session is closed.
        guard !terminal.hasExited || terminal.localProcessTerminalView != nil else { return }
        TerminalProcessCoordinator.shared.appState = appState
        let terminalView = terminal.localProcessTerminalView
            ?? TerminalProcessCoordinator.shared.makeTerminalView(for: terminal, isDark: colorScheme == .dark)

        (terminalView as? AppTerminalView)?.applyAppearance(isDark: colorScheme == .dark)

        if terminalView.processDelegate !== terminal.processDelegate {
            terminalView.processDelegate = terminal.processDelegate
        }

        container.host(terminalView)
    }
}
