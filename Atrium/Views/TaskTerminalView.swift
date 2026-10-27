import SwiftUI

struct TaskTerminalView: View {
    let session: TaskSession
    var acceptsInputFocus = true
    @Environment(AppState.self) private var appState
    @Environment(TaskSessionController.self) private var sessions

    var body: some View {
        TerminalContainerRepresentable(terminal: session.terminal, appState: appState, acceptsInputFocus: acceptsInputFocus)
            .safeAreaInset(edge: .bottom) {
                if session.terminal.hasExited {
                    Button("Resume Task", systemImage: "play") {
                        sessions.open(session.thread)
                    }
                    .disabled(sessions.isOpening)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
