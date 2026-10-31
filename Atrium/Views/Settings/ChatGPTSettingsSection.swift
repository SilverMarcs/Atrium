import AppKit
import SwiftUI

/// ChatGPT reaching Atrium's tools through OpenAI's Secure MCP Tunnel, which
/// Atrium runs while it's open.
struct ChatGPTSettingsSection: View {
    @Bindable var access: ChatGPTAccess
    @State private var key = ""

    var body: some View {
        Section {
            Toggle("ChatGPT", isOn: Binding(get: { access.isEnabled }, set: { access.setEnabled($0) }))
            if access.isEnabled {
                LabeledContent("Tunnel") {
                    TunnelStatusView(status: access.tunnel.status)
                }
                TextField("Tunnel ID", text: $access.tunnelID, prompt: Text("tunnel_…"))
                SecureField("Runtime key", text: $key, prompt: Text(access.tunnel.hasKey ? "Saved" : "sk-…"))
                    .onSubmit {
                        access.saveKey(key)
                        key = ""
                    }
                LabeledContent("Token") {
                    Button("Reset", role: .destructive) { access.resetToken() }
                }
                LabeledContent("Log") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([access.tunnel.logFile])
                    }
                }
                if let error = access.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("ChatGPT")
        } footer: {
            Text("While Atrium is open, it runs [OpenAI’s tunnel client](https://github.com/openai/tunnel-client) so ChatGPT can use Atrium’s tools, and only those. Create the tunnel and a runtime key with Tunnels Read and Use in [OpenAI Platform](https://platform.openai.com/settings/organization/tunnels), then add the tunnel in ChatGPT as an app with no authentication. Resetting the token shuts out the old one.")
        }
    }
}

private struct TunnelStatusView: View {
    let status: ChatGPTTunnel.Status

    var body: some View {
        switch status {
        case .stopped:
            Text("Off")
        case .needsClient:
            Text("Install with `brew install openai/tools/tunnel-client`")
                .textSelection(.enabled)
        case .needsSetup:
            Text("Add the tunnel ID and runtime key")
        case .starting:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
