import SwiftUI

/// What Diffs adds to the agents it runs: each switch turns a set of tools on or off.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.integrationSettings
        Form {
            Section("Across Chats") {
                Toggle(isOn: $settings.isOrchestratorEnabled) {
                    Label {
                        Text("Orchestrator")
                        Text("Agents can delegate and monitor tasks to other Claude, Codex or Antigravity sessions.")
                    } icon: {
                        SettingsSymbolBadge(symbolName: "bubble.left.and.bubble.right.fill", color: .green)
                    }
                }
            }

            Section {
                Toggle(isOn: $settings.isVisualizationsEnabled) {
                    Label {
                        Text("Visualizations")
                        Text("Agents can show charts, diagrams and mockups in the conversation.")
                    } icon: {
                        SettingsSymbolBadge(symbolName: "chart.bar.xaxis", color: .orange)
                    }
                }
                Toggle(isOn: $settings.isBrowserEnabled) {
                    Label {
                        Text("Browser")
                        Text("Agents can open and use web pages in the chat's Browser tab.")
                    } icon: {
                        SettingsSymbolBadge(symbolName: "globe", color: .blue)
                    }
                }
                Toggle(isOn: hasXcode ? $settings.isSimulatorEnabled : .constant(false)) {
                    Label {
                        Text("Simulator")
                        Text(hasXcode
                            ? "Agents can open and use iPhone and iPad simulators in the chat's Simulator tab."
                            : "Install Xcode to let agents use simulators.")
                    } icon: {
                        SettingsSymbolBadge(symbolName: "iphone", color: .indigo)
                    }
                }
                .disabled(!hasXcode)
                Toggle(isOn: $settings.isSecretRequestsEnabled) {
                    Label {
                        Text("Secret Requests")
                        Text("Agents can ask for API keys and passwords in a private question.")
                    } icon: {
                        SettingsSymbolBadge(symbolName: "key.fill", color: .gray)
                    }
                }
            } header: {
                Text("In the Chat")
            } footer: {
                Text("Agents lose these tools at once and get them when a chat starts or reconnects.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .toolbar {
            ToolbarHeightPlaceholder()
        }
        .task {
            await app.simulators.refreshDevices()
        }
    }

    private var hasXcode: Bool { app.simulators.isAvailable }
}
