import Foundation

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let workspace: Workspace?
    let chat: Chat?
    let children: [SidebarItem]?

    static func forWorkspace(_ workspace: Workspace) -> SidebarItem {
        let chatChildren = workspace.chats
            .filter { !$0.isArchived }
            .sorted { $0.date > $1.date }
            .map { forChat($0) }
        return SidebarItem(
            id: "w:\(workspace.id.uuidString)",
            workspace: workspace,
            chat: nil,
            children: chatChildren.isEmpty ? nil : chatChildren
        )
    }

    static func forChat(_ chat: Chat) -> SidebarItem {
        SidebarItem(
            id: "c:\(chat.id.uuidString)",
            workspace: nil,
            chat: chat,
            children: nil
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        lhs.id == rhs.id
    }
}
