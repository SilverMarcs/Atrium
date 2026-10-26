import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }

            Tab("Agents", systemImage: "puzzlepiece.extension") {
                IntegrationsSettingsView()
            }

            Tab("Companion", systemImage: "iphone") {
                CompanionSettingsView()
            }

            Tab("Updates", systemImage: "arrow.down.circle") {
                UpdatesSettingsView()
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }

            Tab("Credits", systemImage: "heart") {
                CreditsSettingsView()
            }
        }
        .frame(width: 480, height: 460)
    }
}

#Preview {
    let integrations = AgentIntegrationStore(adapters: [])
    let appState = AppState()
    let workspaces = WorkspaceStore()
    let sessions = TaskSessionController(integrations: integrations, appState: appState, workspaces: workspaces)
    SettingsView()
        .environment(UpdaterManager())
        .environment(integrations)
        .environment(CompanionServer(integrations: integrations, sessions: sessions, workspaces: workspaces))
}
