import SwiftUI

struct CompanionSettingsView: View {
    @Environment(CompanionServer.self) private var server

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
                }
            } header: {
                Text("Companion")
            } footer: {
                Text("The Atrium iPhone app can follow your tasks, run commands and manage Git from the same network.")
            }

            if server.isEnabled {
                Section {
                    LabeledContent("Pairing code") {
                        Text(server.pairing.code)
                            .font(.title2.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    Button("New Code") { server.pairing.regenerateCode() }
                } header: {
                    Text("Pair an iPhone")
                } footer: {
                    Text("Enter this code in the Atrium iPhone app. Each code works once.")
                }

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
