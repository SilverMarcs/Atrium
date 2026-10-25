import SwiftUI

struct PairingScreen: View {
    @Environment(CompanionClient.self) private var client
    @State private var code = ""
    @State private var selectedHost: DiscoveredHost?

    var body: some View {
        Form {
            Section {
                if client.hosts.isEmpty {
                    Label {
                        Text("Looking for Atrium on this network…")
                    } icon: {
                        ProgressView()
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(client.hosts) { host in
                        HostRow(host: host, isSelected: effectiveHost?.id == host.id) {
                            selectedHost = host
                        }
                    }
                }
            } header: {
                Text("Your Macs")
            } footer: {
                Text("Your Mac must be running Atrium on the same network, with the companion turned on in Settings.")
            }

            Section {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                Button("Pair") {
                    if let effectiveHost { client.pair(with: effectiveHost, code: code) }
                }
                .disabled(effectiveHost == nil || code.count != 6 || isConnecting)
            } header: {
                Text("Pairing Code")
            } footer: {
                Text("Find the code in Atrium → Settings → Companion on your Mac.")
            }

            PairingStatusSection()
        }
        .navigationTitle("Atrium")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isConnecting: Bool {
        if case .connecting = client.state { return true }
        return false
    }

    /// With one Mac on the network, it's chosen without a tap.
    private var effectiveHost: DiscoveredHost? {
        if let selectedHost, client.hosts.contains(selectedHost) { return selectedHost }
        return client.hosts.count == 1 ? client.hosts.first : nil
    }
}
