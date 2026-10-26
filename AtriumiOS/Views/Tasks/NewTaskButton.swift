import SwiftUI

/// Starts a new task, while connected to the host.
struct NewTaskButton: View {
    @Environment(CompanionClient.self) private var client
    let action: () -> Void

    var body: some View {
        Button("New Task", systemImage: "square.and.pencil", action: action)
            .disabled(!client.isConnected)
    }
}
