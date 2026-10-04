import Foundation

extension Chat {
    func handle(_ event: AgentEvent) {
        switch event {
        case .session(let id, let title):
            backendSessionID = id
            if let title, !title.isEmpty { self.title = title }
        case .text(let id, let text, let append):
            contentMessage(id: id, type: .text).updateContent(id: id, type: .text, text: text, append: append)
        case .thought(let id, let text, let append):
            contentMessage(id: id, type: .thought).updateContent(id: id, type: .thought, text: text, append: append)
        case .tool(let id, let title, let kind, let status, let diff):
            let message = messages.last { $0.blocks.contains { $0.toolCallId == id } } ?? turnMessage()
            if message.blocks.contains(where: { $0.toolCallId == id }) {
                message.updateToolCall(id: id, title: title, kind: kind, status: status, diff: diff)
            } else {
                message.addToolCall(toolCallId: id, title: title, kind: kind, status: status, diff: diff)
            }
        case .usage(let used, let capacity): usedTokens = used; contextSize = capacity
        case .plan(let entries): plan = entries
        case .permission: notify("Permission requested")
        case .question: notify("Answer requested")
        case .userReply(let text):
            if !sendMessage(text) { session.fail(AgentError(message: "The question answer could not be sent while the session is busy")) }
        case .turnFinished(let interrupted):
            turnCount += 1
            date = Date()
            currentTurnMessage = nil
            if !interrupted { notify("Finished responding") }
        case .model: model = session.model
        case .questionResolved, .permissionResolved, .turnStarted: break
        }
        scheduleSave()
    }

    private func contentMessage(id: String, type: MessageBlock.BlockType) -> Message {
        messages.last { $0.blocks.contains { $0.sourceID == id && $0.type == type } } ?? turnMessage()
    }

    private func turnMessage() -> Message {
        if let currentTurnMessage { return currentTurnMessage }
        let message = Message(role: .assistant, turnIndex: turnCount + 1)
        message.chat = self
        messages.append(message)
        currentTurnMessage = message
        return message
    }
}
