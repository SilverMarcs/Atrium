import SwiftUI

/// Pairing happens through the host's QR code: scanning it with the Camera opens
/// the app with the link, or the link can be pasted here.
struct PairingScreen: View {
    @Environment(CompanionClient.self) private var client

    @State private var pairingLink = ""
    @State private var showsScanner = false

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Open Atrium → Settings → Companion on your host and turn on the iPhone companion.")
                } icon: {
                    Image(systemName: "macbook")
                }
                Label {
                    Text("Scan its QR code using the button above, or paste its pairing link below.")
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                }
            } header: {
                Text("Pair with Your Host")
            } footer: {
                Text("The connection is end-to-end encrypted.")
            }

            Section {
                if let url = URL(string: "https://github.com/SilverMarcs/Atrium/releases/latest") {
                    Link(destination: url) {
                        Label("Download Atrium for Mac", systemImage: "arrow.down.circle")
                    }
                }
            }

            Section {
                TextField("Paste the pairing link from your host", text: $pairingLink)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(client.isPairing)
                    .onChange(of: pairingLink) { pairWithEnteredLink() }
            }

            PairingStatusSection()
        }
        .navigationTitle("Atrium")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                    showsScanner = true
                }
                .disabled(client.isPairing)
            }
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerSheet { link in
                showsScanner = false
                client.pair(with: link)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func pairWithEnteredLink() {
        guard !client.isPairing,
              let url = URL(string: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = CompanionPairingLink(url: url) else { return }
        client.pair(with: link)
    }
}
