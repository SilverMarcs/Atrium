import SwiftUI

/// The paired hosts: rename one, forget one, or pair another, which opens the
/// same pairing screen the app starts with.
struct HostsSheet: View {
    @Environment(HostDirectory.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var path: [HostsRoute] = []
    @State private var hostToRename: HostClient?
    @State private var hostToForget: HostClient?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(hosts.hosts) { host in
                        HostRow(host: host) { hostToRename = host }
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
        .onChange(of: hosts.pairingCount) { path = [] }
        .hostRenameAlert($hostToRename, in: hosts)
        .alert("Forget This Host?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }),
               presenting: hostToForget) { host in
            Button("Forget", role: .destructive) { hosts.forget(host) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("To use “\(host.name)” again, scan a new QR code from its Atrium Settings.")
        }
    }
}
