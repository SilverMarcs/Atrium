import SwiftUI

/// Pairing happens through the Mac's QR code: scanning it with the Camera opens
/// the app with the link, or the link can be pasted here.
struct PairingScreen: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Open Atrium → Settings → Companion on your Mac and turn on the iPhone companion.")
                } icon: {
                    Image(systemName: "macbook")
                }
                Label {
                    Text("Scan its QR code with the Camera app, or share the pairing link to this iPhone and open it.")
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                }
            } header: {
                Text("Pair with Your Mac")
            } footer: {
                Text("Your iPhone reaches the Mac from any network. The connection is end-to-end encrypted.")
            }

            Section {
                PasteButton(payloadType: URL.self) { urls in
                    if let url = urls.first { client.handle(url) }
                }
            } footer: {
                Text("Copied the pairing link? Paste it here instead.")
            }

            PairingStatusSection()
        }
        .navigationTitle("Atrium")
        .navigationBarTitleDisplayMode(.inline)
    }
}
