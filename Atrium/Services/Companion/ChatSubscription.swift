import Foundation
import Network
import Observation

@MainActor
final class ChatSubscription {
    private weak var chat: Chat?
    private let send: @MainActor (WireSessionPatch) -> Void
    private var lastSnapshot: WireSession?
    private var invalidated = false

    init(chat: Chat, send: @escaping @MainActor (WireSessionPatch) -> Void) {
        self.chat = chat
        self.send = send
    }

    func start() {
        guard let chat else { return }
        lastSnapshot = WireSnapshotter.session(for: chat)
        arm()
    }

    func invalidate() {
        invalidated = true
    }

    private func arm() {
        guard !invalidated, let chat else { return }
        withObservationTracking { [weak self] in
            guard let self, let chat = self.chat else { return }
            _ = chat.title
            _ = chat.turnCount
            _ = chat.date
            _ = chat.usedTokens
            _ = chat.contextSize
            _ = chat.model
            _ = chat.reasoningLevel
            _ = chat.session.models
            _ = chat.session.permissionModes
            _ = ModelCatalog.shared.models(for: chat.provider)
            _ = ModelCatalog.shared.permissionModes(for: chat.provider)
            _ = chat.permissionMode
            _ = chat.session.isProcessing
            _ = chat.session.error
            _ = chat.session.canSteer
            _ = chat.session.activeTurnToken
            _ = chat.session.questions
            for msg in chat.messages {
                _ = msg.blocksData
                _ = msg.role
                _ = msg.turnIndex
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.invalidated else { return }
                self.diffAndSend()
                self.arm()
            }
        }
    }

    private func diffAndSend() {
        guard let chat else { return }
        let now = WireSnapshotter.session(for: chat)
        var patch = WireSessionPatch()
        if now.meta.title != lastSnapshot?.meta.title { patch.title = now.meta.title }
        if now.meta.date != lastSnapshot?.meta.date { patch.date = now.meta.date }
        if now.meta.turnCount != lastSnapshot?.meta.turnCount { patch.turnCount = now.meta.turnCount }
        if now.meta.isConnecting != lastSnapshot?.meta.isConnecting { patch.isConnecting = now.meta.isConnecting }
        if now.meta.isActive != lastSnapshot?.meta.isActive { patch.isActive = now.meta.isActive }
        if now.meta.isProcessing != lastSnapshot?.meta.isProcessing { patch.isProcessing = now.meta.isProcessing }
        if now.messages != lastSnapshot?.messages { patch.messages = now.messages }
        if now.availableModels != lastSnapshot?.availableModels { patch.availableModels = now.availableModels }
        if now.availableModes != lastSnapshot?.availableModes { patch.availableModes = now.availableModes }
        if now.reasoningLevel != lastSnapshot?.reasoningLevel { patch.reasoningLevel = now.reasoningLevel }
        if now.modelLabel != lastSnapshot?.modelLabel { patch.modelLabel = now.modelLabel }
        if now.permissionLabel != lastSnapshot?.permissionLabel { patch.permissionLabel = now.permissionLabel }
        if now.permissionSystemImage != lastSnapshot?.permissionSystemImage {
            patch.permissionSystemImage = now.permissionSystemImage
        }
        if now.usedTokens != lastSnapshot?.usedTokens { patch.usedTokens = now.usedTokens }
        if now.contextSize != lastSnapshot?.contextSize { patch.contextSize = now.contextSize }
        if now.modelRawValue != lastSnapshot?.modelRawValue { patch.modelRawValue = now.modelRawValue }
        if now.permissionModeRawValue != lastSnapshot?.permissionModeRawValue {
            patch.permissionModeRawValue = now.permissionModeRawValue
        }
        if now.activeTurnToken != lastSnapshot?.activeTurnToken { patch.activeTurnToken = now.activeTurnToken }
        if now.canSteer != lastSnapshot?.canSteer { patch.canSteer = now.canSteer }
        if now.questions != lastSnapshot?.questions { patch.questions = now.questions }
        if now.error != lastSnapshot?.error {
            patch.error = now.error
            patch.errorChanged = true
        }
        lastSnapshot = now
        if patch.title == nil && patch.date == nil && patch.turnCount == nil
            && patch.isConnecting == nil && patch.isActive == nil && patch.isProcessing == nil && patch.messages == nil
            && patch.modelLabel == nil && patch.permissionLabel == nil
            && patch.permissionSystemImage == nil
            && patch.usedTokens == nil && patch.contextSize == nil
            && patch.modelRawValue == nil && patch.permissionModeRawValue == nil
            && patch.activeTurnToken == nil && patch.canSteer == nil && patch.questions == nil && patch.errorChanged == nil && patch.availableModels == nil && patch.availableModes == nil && patch.reasoningLevel == nil {
            return
        }
        send(patch)
    }
}
