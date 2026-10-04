import Foundation

extension Chat {
    func connectIfNeeded(retry: Bool = false) {
        guard !session.isConnected, !session.isConnecting, session.error == nil || retry else { return }
        session.permissionMode = permissionMode
        session.model = model
        session.reasoningLevel = reasoningLevel
        session.usedTokens = usedTokens
        session.contextSize = contextSize
        session.plan = plan
        wireSession()
        session.connect(provider: provider, directory: workspace?.directory ?? URL.homeDirectory.path, sessionID: backendSessionID)
    }

    @discardableResult
    func sendMessage(_ text: String, attachments: [ChatAttachment] = [], steeringOnly: Bool = false) -> Bool {
        guard !session.isConnecting, !session.isProcessing || session.canSteer else { return false }
        guard !steeringOnly || session.canSteer else { return false }
        var blocks: [MessageBlock] = []
        var images: [String] = []
        if !text.isEmpty { blocks.append(MessageBlock(type: .text, text: text)) }
        do {
            for attachment in attachments {
                let filename = try ChatImageStore.save(data: attachment.data, extensionHint: ChatImageStore.fileExtension(forMimeType: attachment.mimeType))
                blocks.append(MessageBlock(type: .image, imageFilename: filename))
                images.append(ChatImageStore.directory.appending(path: filename).path)
            }
        } catch {
            session.fail(error)
            return false
        }
        guard !blocks.isEmpty else { return false }
        let message = Message(role: .user, turnIndex: turnCount + 1)
        message.blocks = blocks
        message.chat = self
        messages.append(message)
        date = Date()
        pendingAttachments.removeAll()
        let input = AgentInput(text: text, imagePaths: images)
        if session.canSteer {
            currentTurnMessage = nil
            session.steer(input)
        } else {
            let assistant = Message(role: .assistant, turnIndex: turnCount + 1)
            assistant.chat = self
            messages.append(assistant)
            currentTurnMessage = assistant
            if session.isConnected { session.send(input) }
            else { pendingContent = input; connectIfNeeded(retry: true) }
        }
        scheduleSave()
        return true
    }

    func disconnect() { session.disconnect() }

    func selectModel(_ value: String) {
        session.applyModel(value)
        model = session.model
        reasoningLevel = session.reasoningLevel
        scheduleSave()
    }

    func selectReasoningLevel(_ value: String) {
        session.applyReasoningLevel(value)
        reasoningLevel = session.reasoningLevel
        scheduleSave()
    }

    func selectPermissionMode(_ value: String) {
        session.applyPermissionMode(value)
        permissionMode = session.permissionMode
        scheduleSave()
    }

    private func wireSession() {
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onConnected = { [weak self] in
            guard let self else { return }
            permissionMode = session.permissionMode
            model = session.model
            reasoningLevel = session.reasoningLevel
            backendSessionID = session.sessionID
            scheduleSave()
            if let input = pendingContent { pendingContent = nil; session.send(input) }
        }
        session.onFailure = { [weak self] in
            guard let self else { return }
            backendSessionID = session.sessionID
            pendingContent = nil
            currentTurnMessage = nil
            scheduleSave()
        }
    }
}
