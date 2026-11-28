import SwiftUI

/// This Mac as a host other devices connect to, and every host this Mac shows,
/// itself included. Every connected host's tasks show in the window at once.
struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showingPairHost = false

    var body: some View {
        Form {
            if let host = app.localHost {
                ThisMacSections(host: host)
            }
            HostsSection(hosts: app.hosts)
        }
        .formStyle(.grouped)
        .navigationTitle("Remote")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingPairHost = true
                } label: {
                    Label("Pair Host…", systemImage: "plus")
                }
                .help("Pair with another Mac running Diffs")

                if let url = URL(string: "https://apps.apple.com/app/id6765783787") {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Get iOS App", systemImage: "iphone")
                    }
                    .help("Get the Diffs iOS Companion App")
                }
            }
        }
        .sheet(isPresented: $showingPairHost) {
            PairHostSheet(hosts: app.hosts)
        }
    }
}

/// This Mac as a host: its advertised name and icon, remote access, pairing,
/// and the devices paired with it.
private struct ThisMacSections: View {
    let host: HostClient
    @State private var hostName = ""
    @FocusState private var isEditingHostName: Bool

    private var access: WireRemoteAccess? { host.remoteAccess }

    var body: some View {
        Section {
            TextField("Name", text: $hostName, prompt: Text(access?.defaultHostName ?? ""))
                .focused($isEditingHostName)
                .disabled(access == nil)
                .onSubmit { commitHostName(normalizingField: true) }
                .onChange(of: isEditingHostName) {
                    if !isEditingHostName { commitHostName(normalizingField: true) }
                }
                .onChange(of: access?.customHostName, initial: true) {
                    if !isEditingHostName { hostName = access?.customHostName ?? "" }
                }
                .task(id: hostName) {
                    guard isEditingHostName else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    commitHostName(normalizingField: false)
                }
                .onDisappear { commitHostName(normalizingField: false) }
            Picker("Icon", selection: Binding(
                get: { host.icon },
                set: { host.send(.setHostIcon($0)) }
            )) {
                ForEach(HostIcon.allCases) { icon in
                    Image(systemName: icon.symbolName)
                        .help(icon.title)
                        .accessibilityLabel(icon.title)
                        .tag(icon)
                }
            }
            .pickerStyle(.segmented)
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
            Text("Your iPhone and other Macs running Diffs connect to this Mac with end-to-end encryption and show its name and icon.")
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity)
                HStack {
                    Button("Copy Pairing Link", systemImage: "doc.on.doc") {
                        Pasteboard.copy(url.absoluteString)
                    }
                    Spacer()
                    ShareLink("Share", item: url)
                }
            } header: {
                Text("Pair a Device")
            } footer: {
                Text("Scan this with your iPhone’s Camera, or paste the link into Diffs on another Mac. Each link works once.")
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func commitHostName(normalizingField: Bool) {
        guard let access else { return }
        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizingField { hostName = trimmed }
        guard trimmed != (access.customHostName ?? "") else { return }
        host.send(.setHostName(trimmed))
    }
}

/// Other Macs this Mac connects to as a client.
private struct HostsSection: View {
    let hosts: HostDirectory

    var body: some View {
        Section {
            if hosts.remoteHosts.isEmpty {
                Text("No other hosts paired")
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts.remoteHosts) { host in
                LabeledContent {
                    Button("Remove", role: .destructive) { hosts.forget(host) }
                } label: {
                    HostLabel(host: host)
                }
            }
        } header: {
            Text("Other Hosts")
        } footer: {
            Text("Use + in the toolbar to paste a pairing link from another Mac’s Diffs Settings.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Modal sheet to paste a pairing link from another Mac's Atrium Settings.
private struct PairHostSheet: View {
    let hosts: HostDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a Host")
                .font(.headline)

            Text("Copy the pairing link from Settings → Remote on another Mac running Diffs and paste it below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Pairing link", text: $link, prompt: Text("atrium://pair?…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(pair)

            if let error = hosts.pairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if hosts.pairing != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Pair", action: pair)
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hosts.pairing != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: hosts.pairingCount) { dismiss() }
    }

    private func pair() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let parsed = PairingLink(url: url) else {
            hosts.pairingFailed(message: "That isn’t a Diffs pairing link.")
            return
        }
        hosts.pair(with: parsed)
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
