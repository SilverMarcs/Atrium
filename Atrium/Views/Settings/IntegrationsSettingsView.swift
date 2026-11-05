import SwiftUI

/// What Atrium adds to the agents it runs. Each switch decides what new chats
/// are told; chats keep what they started with, so their cached prompts stay valid.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.integrationSettings
        Form {
            Section {
                Toggle(isOn: $settings.isOrchestratorEnabled) {
                    Text("Orchestrator")
                    Text("Agents can delegate and monitor tasks to other Claude or Codex sessions.")
                }
                Toggle(isOn: $settings.isVisualizationsEnabled) {
                    Text("Visualizations")
                    Text("Agents can show charts, diagrams and mockups in the conversation.")
                }
            } footer: {
                Text("New chats get the instructions that are on when they start.")
            }
        }
        .formStyle(.grouped)
    }
}
