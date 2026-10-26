import SwiftUI

/// A pairing in progress, or why the last attempt failed.
struct PairingStatusSection: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        if client.isPairing {
            Section {
                Label {
                    Text("Pairing…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            }
        } else if let error = client.pairingError {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
}
