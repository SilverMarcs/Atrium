import SwiftUI

struct CompanionSettingsView: View {
    @State private var server = CompanionServer.shared
    @State private var revealedToken = false
    @Environment(WorkspaceStore.self) private var workspaceStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = server.lastError {
                    LabeledContent("Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }
                LabeledContent("Connected clients") {
                    Text("\(server.clientCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Other devices on your local Wi-Fi can discover Atrium via Bonjour and connect using the pairing code below.")
            }

            Section {
                LabeledContent("Pairing code") {
                    Text(CompanionPairing.displayCode(for: CompanionPairing.token))
                        .font(.title2.monospaced())
                        .textSelection(.enabled)
                }
                
                // LabeledContent("Pairing token") {
                    // if revealedToken {
                        // Text(CompanionPairing.token)
                            // .font(.system(.caption, design: .monospaced))
                            // .textSelection(.enabled)
                            // .lineLimit(2)
                            // .truncationMode(.middle)
                    // } else {
                        // Button("Reveal") { revealedToken = true }
                    // }
                // }
                
                LabeledContent("Regenerate") {
                    Button("New pairing code") {
                        _ = CompanionPairing.regenerate()
                        revealedToken = false
                    }
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Enter the pairing code on the iOS companion app the first time you connect. Regenerating invalidates existing pairings.")
            }

            Section {
                Link(destination: URL(string: Self.iOSAppStoreURL)!) {
                    HStack {
                        Image(systemName: "iphone.gen3")
                        Text("Get Atrium for iPhone")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            } header: {
                Text("Download")
            } footer: {
                Text("Install the iPhone app to chat with your agents while away from your Mac. Both devices must be on the same Wi-Fi.")
            }
        }
        .formStyle(.grouped)
    }

    private static let iOSAppStoreURL = "https://apps.apple.com/app/id6765783787"

    private var statusText: String {
        if server.isRunning {
            return server.port > 0 ? "Listening on port \(server.port)" : "Starting…"
        }
        return "Stopped"
    }
}

#Preview {
    CompanionSettingsView()
        .environment(WorkspaceStore())
}
