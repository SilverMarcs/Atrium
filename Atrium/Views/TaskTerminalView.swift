import SwiftUI

struct TaskTerminalView: View {
    let session: TaskSession
    let terminals: HostTerminals
    var acceptsInputFocus = true

    var body: some View {
        TerminalContainerRepresentable(terminal: session.terminal, acceptsInputFocus: acceptsInputFocus)
            .safeAreaInset(edge: .bottom) {
                if session.terminal.hasExited {
                    Button("Resume Task", systemImage: "play") {
                        Task { await terminals.attachTerminal(to: session) }
                    }
                    .disabled(terminals.isOpening)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
