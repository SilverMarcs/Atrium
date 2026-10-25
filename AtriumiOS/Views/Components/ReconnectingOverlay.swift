import SwiftUI

struct ReconnectingOverlay: View {
    let hostName: String
    let onUnpair: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                ProgressView()
                    .controlSize(.large)
            } description: {
                Text("Reconnecting to \(hostName)…")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Unpair", systemImage: "power", role: .cancel, action: onUnpair)
                }
            }
        }
    }
}
