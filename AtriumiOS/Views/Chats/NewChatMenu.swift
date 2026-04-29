import SwiftUI

/// Mirrors the macOS sidebar's "New Chat" Menu: tap fires the primary
/// action (creates a chat with whatever provider is set as the user's
/// default in the Mac app), long-press opens the submenu to pick a
/// specific provider. The Mac echoes back a `chatCreated` reply with the
/// new session id, and the root view auto-pushes it onto the nav stack.
struct NewChatMenu: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID

    var body: some View {
        Menu {
            ForEach(client.availableProviders, id: \.self) { name in
                Button {
                    client.createChat(workspaceId: workspaceId, providerName: name)
                } label: {
                    Label(name, image: ProviderStyle.symbolName(forProviderName: name))
                }
            }
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        } primaryAction: {
            // nil provider tells the Mac "use the user's defaultChatMode".
            client.createChat(workspaceId: workspaceId, providerName: nil)
        }
    }
}
