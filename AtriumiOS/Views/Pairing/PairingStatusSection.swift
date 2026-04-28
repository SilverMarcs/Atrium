import SwiftUI

/// Shows the in-flight connect/auth/failure status for the pairing screen.
struct PairingStatusSection: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        switch client.state {
        case .connecting(let name):
            Section {
                Text("Connecting to \(name)…")
                    .foregroundStyle(.secondary)
            }
        case .authenticating:
            Section {
                Text("Pairing…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Section {
                Text(message)
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }
}
