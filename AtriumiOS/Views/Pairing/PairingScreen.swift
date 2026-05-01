import SwiftUI

struct PairingScreen: View {
    @Environment(CompanionClient.self) private var client
    @State private var pairingCode: String = ""
    @State private var selectedHost: CompanionClient.DiscoveredHost?

    var body: some View {
        Form {
            Section {
                if client.hosts.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching for Atrium on this network…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(client.hosts) { host in
                        HostRow(host: host, isSelected: effectiveHost?.id == host.id) {
                            selectedHost = host
                        }
                    }
                }
            } header: {
                Text("Discovered hosts")
            } footer: {
                Text("The Mac running Atrium must be on the same Wi-Fi.")
            }

            Section {
                TextField("123456", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospaced())
                Button("Connect") {
                    if let host = effectiveHost {
                        client.connect(to: host, pairingCode: pairingCode)
                    }
                }
                .disabled(effectiveHost == nil || pairingCode.count != 6)
            } header: {
                Text("Pairing code")
            } footer: {
                Text("Open Atrium → Settings → Companion on your Mac to see the 6-digit code.")
            }

            if !savedCode.isEmpty, pairingCode.isEmpty {
                Section {
                    Button("Use saved code (\(savedCode))") {
                        pairingCode = savedCode
                    }
                }
            }

            Section {
                Button {
                    client.enterDemoMode()
                } label: {
                    Label("Try the demo", systemImage: "play.circle")
                }
                Link(destination: URL(string: Self.hostDownloadURL)!) {
                    Label("Download Atrium for Mac", systemImage: "arrow.down.circle")
                }
            } header: {
                Text("No Mac App yet?")
            } footer: {
                // Text("The demo populates fake workspaces so you can explore the UI without a paired host. The download link opens the GitHub releases page for the latest signed Mac build.")
            }

            PairingStatusSection()
        }
    }

    /// Placeholder — point this at the real `releases/latest` page once
    /// the host app has its first notarised GitHub release.
    private static let hostDownloadURL = "https://github.com/SilverMarcs/Atrium/releases/latest"

    private var savedCode: String { client.savedPairingCode }

    /// If the user explicitly tapped a host, use that. Otherwise — when there
    /// is exactly one host on the network — auto-select it so the Connect
    /// button enables purely from typing the code.
    private var effectiveHost: CompanionClient.DiscoveredHost? {
        if let selectedHost { return selectedHost }
        return client.hosts.count == 1 ? client.hosts.first : nil
    }
}
