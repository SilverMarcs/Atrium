import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    @State private var searchText = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    var body: some View {
        NavigationSplitView(columnVisibility: Bindable(appState).sidebarVisibility) {
            ThreadListView(searchText: searchText)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Filter tasks or projects")
        } detail: {
            if let openingThreadID = sessions.openingThreadID, openingThreadID == appState.selectedThreadID {
                ProgressView("Opening task…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = appState.selectedSession {
                TaskDetailView(session: session)
            } else if let error = sessions.openError,
                      let thread = integrations.threads.first(where: { $0.id == appState.selectedThreadID }) {
                ContentUnavailableView {
                    Label("Couldn’t Open Task", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { sessions.open(thread) }
                }
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a task or use Compose to get started.")
                )
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        .inspector(isPresented: Bindable(appState).showingInspector) {
            if let workspace = appState.selectedWorkspace {
                InspectorView(workspace: workspace)
                    .environment(workspace.editorPanel)
                    .inspectorColumnWidth(min: 240, ideal: 240, max: 360)
            } else {
                ContentUnavailableView(
                    "No Inspector",
                    systemImage: "sidebar.right"
                )
            }
        }
        .modifier(TaskIntegrationModifier())
        .focusedSceneValue(\.editorPanel, appState.selectedWorkspace?.editorPanel)
        .focusedSceneValue(\.isMainWindow, true)
        .sheet(isPresented: $showingOnboarding) {
            hasCompletedOnboarding = true
        } content: {
            OnboardingView()
        }
        .task {
            if !hasCompletedOnboarding {
                showingOnboarding = true
            }
        }
        .alert(
            "Replace running command?",
            isPresented: Binding(
                get: { appState.pendingRunReplacement != nil },
                set: { if !$0 { appState.pendingRunReplacement = nil } }
            ),
            presenting: appState.pendingRunReplacement
        ) { command in
            Button("Replace", role: .confirm) {
                command.restart()
            }
            Button("Cancel", role: .cancel) { }
        } message: { command in
            Text("\"\(command.title)\" is currently running. Replacing will stop it and start a new instance.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
            if let threadID = notification.userInfo?["threadID"] as? String,
               let thread = integrations.threads.first(where: { $0.id == threadID }) {
                sessions.open(thread)
                return
            }
            guard let workspaceID = notification.userInfo?["workspaceID"] as? String,
                  let terminalID = notification.userInfo?["terminalID"] as? String else { return }

            if let session = appState.sessions.values.first(where: {
                $0.workspace.id.uuidString == workspaceID && $0.terminal.id.uuidString == terminalID
            }), integrations.enabledProviders.contains(session.thread.provider) {
                appState.show(session)
            } else if let workspace = appState.selectedWorkspace,
                      workspace.id.uuidString == workspaceID,
                      let command = workspace.commands.first(where: { $0.id.uuidString == terminalID }) {
                appState.showingInspector = true
                workspace.inspectorState.selectedTab = .commands
                workspace.inspectorState.selectedCommand = command
            }
        }
    }
}
