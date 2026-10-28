import SwiftUI

/// Pairing happens through the host's QR code: scanning it with the Camera opens
/// the app with the link, or the link can be pasted here.
struct PairingScreen: View {
    @Environment(HostDirectory.self) private var hosts

    @State private var pairingLink = ""
    @State private var showsScanner = false

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Open Atrium → Settings → Hosts on your Mac and turn on remote access.")
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
                    .disabled((hosts.pairing != nil))
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
                .disabled((hosts.pairing != nil))
            }
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerSheet { link in
                showsScanner = false
                hosts.pair(with: link)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func pairWithEnteredLink() {
        guard !(hosts.pairing != nil),
              let url = URL(string: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = PairingLink(url: url) else { return }
        hosts.pair(with: link)
    }
}
