import SwiftUI

struct ReconnectingOverlay: View {
    let onDisconnect: () -> Void

    var body: some View {
        NavigationStack {
            ProgressView("Reconnecting")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .cancel, action: onDisconnect) {
                            Image(systemName: "power")
                        }
                    }
                }
        }
    }
}
