import SwiftUI

/// The paired hosts: rename one, forget one, or pair another, which opens the
/// same pairing screen the app starts with.
struct HostsSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var path: [HostsRoute] = []
    @State private var hostToRename: PairedHost?
    @State private var hostToForget: PairedHost?
    @State private var newName = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(client.pairedHosts) { host in
                        HostRow(host: host, isCurrent: host.id == client.currentHost?.id) {
                            newName = host.displayName
                            hostToRename = host
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash") { hostToForget = host }
                                .tint(.red)
                        }
                    }
                } header: {
                    Text("Paired Hosts")
                } footer: {
                    Text("Tap a host to rename it on this iPhone.")
                }
                Section {
                    NavigationLink(value: HostsRoute.pair) {
                        Label("Pair New Host", systemImage: "plus")
                    }
                }
                DictationSettingsSection()
            }
            .navigationTitle("Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HostsRoute.self) { _ in
                PairingScreen()
                    .navigationTitle("Pair a Host")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .onChange(of: client.pairingCount) { path = [] }
        .alert("Rename Host", isPresented: Binding(get: { hostToRename != nil }, set: { if !$0 { hostToRename = nil } }),
               presenting: hostToRename) { host in
            TextField(host.hostName, text: $newName)
            Button("Rename") { client.rename(host, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("Leave it empty to use “\(host.hostName)”.")
        }
        .alert("Forget This Host?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }),
               presenting: hostToForget) { host in
            Button("Forget", role: .destructive) { client.forget(host) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("To use “\(host.displayName)” again, scan a new QR code from its Atrium Settings.")
        }
    }
}
