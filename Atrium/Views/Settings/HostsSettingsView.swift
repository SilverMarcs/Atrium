import SwiftUI

/// This Mac as a host other devices connect to, and the other hosts this Mac
/// connects to. Every connected host's tasks show in the window at once.
struct HostsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if let host = app.localHost {
                ThisMacSections(host: host)
            }
            OtherHostsSection(hosts: app.hosts)
        }
        .formStyle(.grouped)
    }
}

/// This Mac as a host: remote access, pairing, and the devices paired with it.
private struct ThisMacSections: View {
    let host: HostClient

    private var access: WireRemoteAccess? { host.remoteAccess }

    var body: some View {
        Section {
            Toggle("Allow remote access", isOn: Binding(
                get: { access?.isEnabled ?? false },
                set: { host.send(.setRemoteAccess($0)) }
            ))
            .disabled(access == nil)
            if let access, access.isEnabled {
                LabeledContent("Status") {
                    RemoteAccessStatus(status: access.status)
                }
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("Your iPhone and other Macs running Atrium can connect to this Mac with end-to-end encryption. Terminals stay on this Mac and files are read-only elsewhere.")
        }
        .sectionActions {
            if let url = URL(string: "https://apps.apple.com/app/id6765783787") {
                Link("Get the iOS App", destination: url)
            }
        }
        .task {
            await host.follow(.remoteAccess)
        }

        if let access, let url = access.pairingLink {
            Section {
                HStack {
                    Spacer()
                    PairingQRCodeView(url: url)
                        .frame(width: 160, height: 160)
                        .padding(8)
                        .background(.white, in: .rect(cornerRadius: 8))
                    Spacer()
                }
                HStack {
                    Button("Copy Pairing Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    ShareLink("Share", item: url)
                }
            } header: {
                Text("Pair a Device")
            } footer: {
                Text("Scan this with your iPhone’s Camera, or paste the link into Atrium on another Mac. Each link works once.")
            }

            Section("Paired Devices") {
                if access.devices.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                }
                ForEach(access.devices) { device in
                    PairedDeviceRow(device: device) {
                        host.send(.forgetDevice(device.id))
                    }
                }
            }
        }
    }
}

/// Hosts this Mac connects to as a client, and pairing with a new one.
private struct OtherHostsSection: View {
    let hosts: HostDirectory
    @State private var link = ""

    var body: some View {
        Section {
            ForEach(hosts.remoteHosts) { host in
                LabeledContent {
                    Button("Remove", role: .destructive) { hosts.forget(host) }
                } label: {
                    Label {
                        Text(host.name)
                        HostStatusText(host: host)
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                }
            }
            HStack {
                TextField("Pairing link", text: $link, prompt: Text("atrium://pair?…"))
                    .labelsHidden()
                    .onSubmit(pair)
                if hosts.pairing != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Pair", action: pair)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hosts.pairing != nil)
            }
            if let error = hosts.pairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Other Hosts")
        } footer: {
            Text("Copy the pairing link from Atrium Settings on another Mac and paste it here.")
        }
        .onChange(of: hosts.pairingCount) { link = "" }
    }

    private func pair() {
        guard let link = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(PairingLink.init(url:)) else {
            hosts.pairingFailed(message: "That isn’t an Atrium pairing link.")
            return
        }
        hosts.pair(with: link)
    }
}

private struct HostStatusText: View {
    let host: HostClient

    var body: some View {
        if host.needsAppUpdate {
            Text("Update Atrium to use this host")
        } else {
            switch host.state {
            case .connected: Text(host.route == .localNetwork ? "Connected on this network" : "Connected through the relay")
            case .connecting: Text("Connecting…")
            case .offline(let reason): Text(reason)
            }
        }
    }
}

private struct RemoteAccessStatus: View {
    let status: WireRemoteAccess.Status

    var body: some View {
        switch status {
        case .off:
            Text("Off")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting…")
                .foregroundStyle(.secondary)
        case .connected:
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle(color: .green))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct PairedDeviceRow: View {
    let device: WirePairedDevice
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove", role: .destructive, action: onRemove)
        } label: {
            Label {
                Text(device.name)
                if device.isConnected {
                    Text("Connected")
                } else if let lastConnectedAt = device.lastConnectedAt {
                    Text("Last connected \(lastConnectedAt, format: .relative(presentation: .named))")
                }
            } icon: {
                Image(systemName: "laptopcomputer.and.iphone")
            }
        }
    }
}
