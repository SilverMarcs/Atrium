import SwiftUI

/// A pairing in progress, or why the last attempt failed.
struct PairingStatusSection: View {
    @Environment(HostDirectory.self) private var hosts

    var body: some View {
        if hosts.pairing != nil {
            Section {
                Label {
                    Text("Pairing…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            }
        } else if let error = hosts.pairingError {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
}
