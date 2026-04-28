import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        NavigationStack {
            Group {
                switch client.state {
                case .idle, .browsing, .connecting, .authenticating, .failed:
                    PairingScreen()
                case .connected:
                    WorkspacesScreen()
                }
            }
            .navigationTitle("Atrium")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            client.startBrowsing()
        }
    }
}
