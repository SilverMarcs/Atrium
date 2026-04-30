import SwiftUI

/// Full-screen cover shown while the companion is re-establishing its
/// socket after a paired session. Hides stale workspace data behind an
/// opaque background so the user doesn't act on it mid-reconnect, and
/// offers an explicit Disconnect escape hatch in the top-leading corner.
struct ReconnectingOverlay: View {
    let onDisconnect: () -> Void

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button(role: .cancel, action: onDisconnect) {
                    Image(systemName: "power")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .padding()
            }
    }
}
