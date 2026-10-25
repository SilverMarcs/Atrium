import SwiftUI

@main
struct AtriumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var workspaceStore: WorkspaceStore
    @State private var appState: AppState
    @State private var updater = UpdaterManager()
    @State private var integrations: AgentIntegrationStore
    @State private var sessions: TaskSessionController
    @State private var companion: CompanionServer

    init() {
        let workspaceStore = WorkspaceStore()
        let appState = AppState()
        let integrations = AgentIntegrationStore(adapters: [CodexAgentAdapter(), ClaudeAgentAdapter()])
        _workspaceStore = State(initialValue: workspaceStore)
        _appState = State(initialValue: appState)
        _integrations = State(initialValue: integrations)
        let sessions = TaskSessionController(integrations: integrations, appState: appState, workspaces: workspaceStore)
        _sessions = State(initialValue: sessions)
        _companion = State(initialValue: CompanionServer(
            integrations: integrations, sessions: sessions, workspaces: workspaceStore
        ))
    }

    var body: some Scene {
        Window("Atrium", id: "atrium") {
            ContentView()
                .environment(appState)
                .environment(workspaceStore)
                .environment(integrations)
                .environment(sessions)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands(appState: appState, updater: updater, integrations: integrations, sessions: sessions)
        }

        WindowGroup("Diff", for: GitCommitDiffSheetItem.self) { $item in
            if let item {
                GitCommitDiffWindow(item: item)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .restorationBehavior(.disabled)

        Window("About Atrium", id: "about") {
            AboutView()
                .containerBackground(.regularMaterial, for: .window)
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .windowMinimizeBehavior(.disabled)
        }
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(updater)
                .environment(integrations)
                .environment(companion)
        }
    }
}
