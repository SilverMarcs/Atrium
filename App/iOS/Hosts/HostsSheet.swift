import SwiftUI

/// The paired hosts: forget one, or pair another, which opens the same pairing
/// screen the app starts with.
struct HostsSheet: View {
    @Environment(HostDirectory.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var path: [HostsRoute] = []
    @State private var hostToForget: HostClient?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Paired Hosts") {
                    ForEach(hosts.hosts) { host in
                        HostLabel(host: host)
                            .swipeActions {
                                Button("Forget", systemImage: "trash") { hostToForget = host }
                                    .tint(.red)
                            }
                    }
                    NavigationLink(value: HostsRoute.pair) {
                        Label("Pair New Host", systemImage: "plus")
                    }
                }
                SendModeSettingsSection()
                Section("Task List") {
                    TaskRowHostLabelPicker()
                }
                Section {
                    DiffLayoutPicker()
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
        .alert("Forget This Host?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }),
               presenting: hostToForget) { host in
            Button("Forget", role: .destructive) { hosts.forget(host) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("To use “\(host.name)” again, scan a new QR code from its Atrium Settings.")
        }
    }
}
