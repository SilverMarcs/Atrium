import AtriumClient
import AtriumProtocol
import SwiftUI

/// The agents this Mac's own host runs tasks with.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            ForEach(app.localHost?.tasks?.providers ?? []) { provider in
                AgentSettingsSection(provider: provider)
            }
        }
        .formStyle(.grouped)
        // Looks again for agents, which may have been installed since launch.
        .task { app.localHost?.send(.refreshTasks) }
    }
}
