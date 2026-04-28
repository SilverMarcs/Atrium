import SwiftUI

/// "New chat" toolbar control that fans out to a provider picker. Hooks
/// straight into `client.createChat(workspaceId:providerName:)` — the Mac
/// adds the chat to the workspace and the broadcast loop pushes the
/// updated list back.
struct NewChatMenu: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID

    private static let providers = ["Claude", "Codex", "Gemini"]

    var body: some View {
        Menu {
            ForEach(Self.providers, id: \.self) { name in
                Button {
                    client.createChat(workspaceId: workspaceId, providerName: name)
                } label: {
                    Label(name, systemImage: providerSymbol(for: name))
                }
            }
        } label: {
            Label("New Chat", systemImage: "plus.bubble")
        }
    }

    private func providerSymbol(for name: String) -> String {
        switch name {
        case "Claude": return "claude.symbols"
        case "Codex": return "openai.symbols"
        case "Gemini": return "gemini.symbols"
        default: return "sparkles"
        }
    }
}
