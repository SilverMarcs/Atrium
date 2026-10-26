import SwiftUI

/// The paired Macs: rename one, forget one, or pair another, which opens the
/// same pairing screen the app starts with.
struct MacsSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var path: [MacsRoute] = []
    @State private var macToRename: PairedMac?
    @State private var macToForget: PairedMac?
    @State private var newName = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(client.pairedMacs) { mac in
                        MacRow(mac: mac, isCurrent: mac.id == client.currentMac?.id) {
                            newName = mac.displayName
                            macToRename = mac
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash") { macToForget = mac }
                                .tint(.red)
                        }
                    }
                } footer: {
                    Text("Tap a Mac to rename it on this iPhone.")
                }
                Section {
                    NavigationLink(value: MacsRoute.pair) {
                        Label("Pair New Mac", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MacsRoute.self) { _ in
                PairingScreen()
                    .navigationTitle("Pair a Mac")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .onChange(of: client.pairingCount) { path = [] }
        .alert("Rename Mac", isPresented: Binding(get: { macToRename != nil }, set: { if !$0 { macToRename = nil } }),
               presenting: macToRename) { mac in
            TextField(mac.hostName, text: $newName)
            Button("Rename") { client.rename(mac, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { mac in
            Text("Leave it empty to use “\(mac.hostName)”.")
        }
        .alert("Forget This Mac?", isPresented: Binding(get: { macToForget != nil }, set: { if !$0 { macToForget = nil } }),
               presenting: macToForget) { mac in
            Button("Forget", role: .destructive) { client.forget(mac) }
            Button("Cancel", role: .cancel) {}
        } message: { mac in
            Text("To use “\(mac.displayName)” again, scan a new QR code from its Atrium Settings.")
        }
    }
}
