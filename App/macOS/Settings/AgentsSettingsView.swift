import AtriumClient
import AtriumProtocol
import SwiftUI

/// The agents this Mac's own host runs tasks with.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.integrationSettings
        Form {
            Section {
                Picker("Permissions for new chats", selection: $settings.defaultPermissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
            }
            ForEach(app.localHost?.tasks?.providers ?? []) { provider in
                AgentSettingsSection(provider: provider)
            }
        }
        .formStyle(.grouped)
        // Looks again for agents, which may have been installed since launch.
        .task { app.localHost?.send(.refreshTasks) }
    }
}
