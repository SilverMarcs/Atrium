import AppKit
import SwiftUI

/// The tools Atrium gives agents, and ChatGPT's access to them.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(ToolGroup.orchestration.settingsKey) private var isOrchestratorEnabled = ToolGroup.orchestration.isEnabledByDefault
    @AppStorage(ToolGroup.pages.settingsKey) private var isPagesEnabled = ToolGroup.pages.isEnabledByDefault

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isOrchestratorEnabled) {
                    Text("Orchestrator")
                    Text("Sessions can find and read each other, delegate work to Claude or Codex, and get the results back.")
                }
                Toggle(isOn: $isPagesEnabled) {
                    Text("Visualizations")
                    Text("Agents can show charts, diagrams and mockups in the conversation.")
                }
            } header: {
                Text("Agent Tools")
            } footer: {
                Text("Sessions get the tools that are on when they start or resume. Turning a tool off also stops sessions already running from using it.")
            }

            ChatGPTSection(access: app.chatGPTAccess, isOrchestratorEnabled: isOrchestratorEnabled)
        }
        .formStyle(.grouped)
    }
}

/// ChatGPT reaching the Orchestrator through OpenAI's Secure MCP Tunnel.
private struct ChatGPTSection: View {
    let access: ChatGPTAccess
    let isOrchestratorEnabled: Bool

    var body: some View {
        Section {
            if let url = access.serverURL {
                LabeledContent("MCP server URL") {
                    Text(url.absoluteString)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Authorization header") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([access.headerFile])
                }
            }
            LabeledContent("Token") {
                Button("Reset", role: .destructive) { access.resetToken() }
            }
            if let error = access.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("ChatGPT")
        } footer: {
            if isOrchestratorEnabled {
                Text("To use Atrium from ChatGPT, run [OpenAI’s tunnel client](https://github.com/openai/tunnel-client) on this Mac pointed at this URL with the header from the file, then add the tunnel in ChatGPT as a custom MCP server. ChatGPT gets the Orchestrator’s tools only. Resetting the token shuts out the old one.")
            } else {
                Text("Turn on the Orchestrator for ChatGPT to see any tools.")
            }
        }
    }
}
