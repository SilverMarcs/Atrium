import Foundation
import Network

extension ClientHandler {
    func handleAuth(token: String, clientId: UUID?) {
        let expected = CompanionPairing.displayCode(for: CompanionPairing.token)
        let ok = !token.isEmpty && token == expected
        isAuthenticated = ok
        if ok, let clientId {
            self.clientId = clientId
            onAuth(self, clientId)
        }
        var reply = CompanionMessage(kind: .authResult)
        reply.ok = ok
        if !ok { reply.error = "Invalid pairing code" }
        send(reply)
        if !ok {
            connection.cancel()
        }
    }

    func sendSessionsList() {
        guard let store else { return }
        let workspaces = store.workspaces.map { ws in
            WireWorkspace(
                id: ws.id,
                name: ws.name,
                customIconData: WireSnapshotter.customIconBytes(for: ws),
                isArchived: ws.isArchived,
                hasActiveChildProcess: ws.hasActiveChildProcess,
                scratchpad: ws.scratchPad,
                sessions: ws.chats.sorted { $0.sortOrder < $1.sortOrder }.map { chat in
                    WireSnapshotter.meta(for: chat, in: ws)
                }
            )
        }
        var msg = CompanionMessage(kind: .sessionsList)
        msg.workspaces = workspaces
        msg.availableProviders = AgentProvider.allCases.map(\.rawValue)
        send(msg)
    }

    func subscribe(to sessionId: UUID) {
        subscription?.invalidate()
        subscription = nil
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else {
            sendError("session not found")
            return
        }
        if chat.hasNotification { chat.hasNotification = false }
        var snap = CompanionMessage(kind: .sessionSnapshot)
        snap.sessionId = chat.id
        snap.session = WireSnapshotter.session(for: chat)
        send(snap)

        let sub = ChatSubscription(chat: chat) { [weak self] patch in
            guard let self else { return }
            var update = CompanionMessage(kind: .sessionUpdate)
            update.sessionId = chat.id
            update.patch = patch
            self.send(update)
        }
        sub.start()
        self.subscription = sub
    }

    func sendPrompt(sessionId: UUID, text: String) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else {
            sendError("session not found")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if chat.session.isProcessing || !chat.sendMessage(trimmed) { sendError("Chat is busy or connecting") }
    }

    func toggleArchive(sessionId: UUID) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        if !chat.isArchived {
            chat.disconnect()
        }
        chat.isArchived.toggle()
        chat.workspace?.store?.scheduleSave()
    }

    func disconnectChat(sessionId: UUID) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        chat.disconnect()
    }

    func stopChat(sessionId: UUID) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        chat.session.stopStreaming()
    }

    func deleteChat(sessionId: UUID) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        if subscription != nil { subscription?.invalidate(); subscription = nil }
        chat.workspace?.removeChat(chat)
    }

    func createChat(workspaceId: UUID, providerName: String?) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        let provider: AgentProvider = {
            if let name = providerName,
               let p = AgentProvider.allCases.first(where: { $0.rawValue == name }) {
                return p
            }
            if let raw = UserDefaults.standard.string(forKey: "defaultChatMode"),
               let p = AgentProvider(rawValue: raw) {
                return p
            }
            return .codex
        }()
        let permissionMode = UserDefaults.standard.string(forKey: "defaultPermissionMode") ?? ""
        let chat = workspace.addChat(provider: provider, permissionMode: permissionMode)
        var reply = CompanionMessage(kind: .chatCreated)
        reply.workspaceId = workspaceId
        reply.sessionId = chat.id
        send(reply)
    }

    func updateScratchpad(workspaceId: UUID, text: String) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.scratchPad = text
    }

    func setSessionModel(sessionId: UUID, modelRawValue: String) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        let known = ModelCatalog.shared.models(for: chat.provider)
        guard known.contains(where: { $0.rawValue == modelRawValue }) else {
            sendError("invalid model")
            return
        }
        chat.selectModel(modelRawValue)
    }

    func setSessionPermissionMode(sessionId: UUID, modeRawValue: String) {
        guard let store, let chat = WireSnapshotter.findChat(id: sessionId, in: store) else { return }
        guard chat.permissionModes.contains(where: { $0.rawValue == modeRawValue }) else {
            sendError("invalid permission mode")
            return
        }
        chat.selectPermissionMode(modeRawValue)
    }


}
