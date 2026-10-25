import SwiftUI

/// The in-flight connection or the reason the last attempt failed.
struct PairingStatusSection: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        switch client.state {
        case .connecting(let hostName):
            Section {
                Label {
                    Text("Pairing with \(hostName)…")
                } icon: {
                    ProgressView()
                }
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
