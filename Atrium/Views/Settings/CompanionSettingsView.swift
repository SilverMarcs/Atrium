import SwiftUI

struct CompanionSettingsView: View {
    @Environment(CompanionServer.self) private var server
    @State private var relayDraft = ""

    var body: some View {
        @Bindable var server = server
        Form {
            Section {
                Toggle("Allow iPhone companion", isOn: $server.isEnabled)
                if server.isEnabled {
                    LabeledContent("Status") {
                        CompanionStatusLabel(status: server.status)
                    }
                    LabeledContent("Connected") {
                        Text(server.connectedDevices.isEmpty
                            ? "No devices"
                            : server.connectedDevices.map(\.name).formatted(.list(type: .and)))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Relay", text: $relayDraft, prompt: Text("wss://relay.example.com"))
                        .onSubmit { server.relayAddress = relayDraft }
                        .onChange(of: server.relayAddress, initial: true) { relayDraft = server.relayAddress }
                }
            } header: {
                Text("Companion")
            } footer: {
                Text("The Atrium iPhone app can follow your tasks, send prompts, run commands and manage Git from any network. It connects through the relay with end-to-end encryption, so the relay only passes data it can’t read. Your Mac stays awake while this is on.")
            }

            if server.isEnabled, let url = server.pairingLink?.url {
                Section {
                    HStack {
                        Spacer()
                        PairingQRCodeView(url: url)
                            .frame(width: 180, height: 180)
                            .padding(8)
                            .background(.white, in: .rect(cornerRadius: 8))
                        Spacer()
                    }
                    ShareLink("Share Pairing Link", item: url)
                    Button("New QR Code") { server.pairing.regenerateSecret() }
                } header: {
                    Text("Pair an iPhone")
                } footer: {
                    Text("Scan this with your iPhone’s Camera, or send the link to your iPhone and open it there. Each code works once.")
                }
            }

            if server.isEnabled {
                Section("Paired Devices") {
                    if server.pairing.devices.isEmpty {
                        Text("No paired devices")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(server.pairing.devices) { device in
                        CompanionDeviceRow(device: device, isConnected: server.connectedDevices.contains { $0.id == device.id }) {
                            server.remove(device)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
