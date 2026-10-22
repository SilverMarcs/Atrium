import SwiftUI

@MainActor
@Observable
final class AppState {
    private(set) var sessions: [String: TaskSession] = [:]
    private(set) var selectedThreadID: String?
    var selectedSession: TaskSession? { selectedThreadID.flatMap { sessions[$0] } }
    var showingCompose = false
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    var showingInspector = true
    var pendingRunReplacement: Terminal?

    var selectedWorkspace: Workspace? { selectedSession?.workspace }
    var activeTerminal: Terminal? { selectedSession?.terminal }

    func selectThread(_ id: String) {
        selectedThreadID = id
    }

    func show(_ session: TaskSession) {
        sessions[session.id] = session
        selectedThreadID = session.id
        session.terminal.hasBellNotification = false
    }

    func closeSession(_ id: String) {
        if selectedThreadID == id {
            selectedThreadID = nil
        }
        sessions.removeValue(forKey: id)?.terminal.terminate()
    }

    func updateSessions(_ threads: [AgentThread], enabledProviders: [AgentProvider]) {
        for thread in threads {
            sessions[thread.id]?.thread = thread
            sessions[thread.id]?.terminal.title = thread.title
        }
        if let selectedThreadID,
           let provider = sessions[selectedThreadID]?.thread.provider ?? threads.first(where: { $0.id == selectedThreadID })?.provider,
           !enabledProviders.contains(provider) {
            self.selectedThreadID = nil
        }
    }
}
