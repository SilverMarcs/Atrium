import Foundation

@MainActor
enum WireSnapshotter {
    private static let maxIconBytes = 512 * 1024

    static func findChat(id: UUID, in store: WorkspaceStore) -> Chat? {
        for ws in store.workspaces {
            if let chat = ws.chats.first(where: { $0.id == id }) { return chat }
        }
        return nil
    }

    static func customIconBytes(for workspace: Workspace) -> Data? {
        guard let url = workspace.customIconURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count <= maxIconBytes else { return nil }
        return data
    }

    static func meta(for chat: Chat, in workspace: Workspace) -> WireSessionMeta {
        WireSessionMeta(
            id: chat.id,
            workspaceId: workspace.id,
            title: chat.displayTitle,
            date: chat.date,
            turnCount: chat.turnCount,
            isProcessing: chat.session.isProcessing,
            isArchived: chat.isArchived,
            providerName: chat.provider.rawValue,
            isActive: chat.session.isConnected,
            hasNotification: chat.hasNotification,
            isConnecting: chat.session.isConnecting
        )
    }

    static func session(for chat: Chat) -> WireSession {
        let workspace = chat.workspace
        let meta = WireSessionMeta(
            id: chat.id,
            workspaceId: workspace?.id ?? UUID(),
            title: chat.displayTitle,
            date: chat.date,
            turnCount: chat.turnCount,
            isProcessing: chat.session.isProcessing,
            isArchived: chat.isArchived,
            providerName: chat.provider.rawValue,
            isActive: chat.session.isConnected,
            hasNotification: chat.hasNotification,
            isConnecting: chat.session.isConnecting
        )
        let models = chat.session.models.isEmpty ? ModelCatalog.shared.models(for: chat.provider) : chat.session.models
        let availableModels = models.map {
            WireAgentModel(rawValue: $0.rawValue, name: $0.name, imageName: $0.imageName, reasoningLevels: $0.reasoningLevels.map { WireReasoningLevel(id: $0.id, name: $0.name, description: $0.description) })
        }
        let availableModes = chat.permissionModes.map {
            WirePermissionMode(
                rawValue: $0.rawValue,
                label: $0.label,
                systemImage: $0.systemImage,
                description: $0.description
            )
        }
        return WireSession(
            meta: meta,
            messages: chat.messages.map(wireMessage(_:)),
            modelLabel: availableModels.first(where: { $0.rawValue == chat.model })?.name ?? chat.model,
            permissionLabel: chat.selectedPermissionMode?.label ?? "Provider Default",
            permissionSystemImage: chat.selectedPermissionMode?.systemImage ?? "shield",
            usedTokens: chat.usedTokens,
            contextSize: chat.contextSize,
            availableModels: availableModels,
            modelRawValue: chat.model,
            availableModes: availableModes,
            permissionModeRawValue: chat.permissionMode,
            reasoningLevel: chat.reasoningLevel,
            activeTurnToken: chat.session.activeTurnToken,
            canSteer: chat.session.canSteer,
            questions: chat.session.questions.map(\.prompt),
            error: chat.session.error
        )
    }

    private static func wireMessage(_ m: Message) -> WireMessage {
        let role: WireMessage.Role = (m.role == .user) ? .user : .assistant
        var blocks: [WireBlock] = []
        var pendingText: String = ""
        func flushText() {
            if !pendingText.isEmpty {
                blocks.append(WireBlock(id: UUID(), kind: .text, text: pendingText))
                pendingText = ""
            }
        }
        for block in m.blocks {
            switch block.type {
            case .text:
                pendingText += block.text
            case .thought:
                break
            case .toolCall:
                flushText()
                blocks.append(WireBlock(
                    id: block.id,
                    kind: .toolCall,
                    text: block.toolTitle ?? block.toolKind?.rawValue.capitalized ?? "Tool",
                    toolSymbolName: block.toolKind?.symbolName ?? "wrench.and.screwdriver"
                ))
            case .image:
                flushText()
                blocks.append(WireBlock(
                    id: block.id,
                    kind: .toolCall,
                    text: "Image",
                    toolSymbolName: "photo"
                ))
            }
        }
        flushText()
        return WireMessage(
            id: m.id,
            role: role,
            turnIndex: m.turnIndex,
            blocks: blocks
        )
    }
}
