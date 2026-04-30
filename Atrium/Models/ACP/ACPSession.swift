import Foundation
import ACP
import ACPModel

@Observable
final class ACPSession {
    var isConnected = false
    var isConnecting = false
    var isProcessing = false
    var error: String?
    var provider: AgentProvider = .codex
    var permissionMode: PermissionMode = .bypassPermissions
    var model: String = ""
    var usedTokens: Int = 0
    var contextSize: Int = 0
    var plan: [PlanEntry] = []
    var availableCommands: [AvailableCommand] = []

    var onTurnComplete: (() async -> Void)?
    var onConnected: (() -> Void)?
    var onSessionUpdate: ((SessionUpdate) -> Void)?

    @ObservationIgnored private(set) var client: Client?
    @ObservationIgnored private(set) var sessionId: SessionId?
    @ObservationIgnored var notificationTask: Task<Void, Never>?
    @ObservationIgnored private(set) var workingDirectory: String = ""
    @ObservationIgnored let delegate = ACPSessionDelegate()
    @ObservationIgnored var isReplaying = false

    func connect(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        Task {
            await launchAndCreateSession()
        }
    }

    func newSession() {
        isConnecting = true
        Task {
            await terminateAndRelaunch()
        }
    }

    func disconnect() {
        notificationTask?.cancel()
        notificationTask = nil
        onTurnComplete = nil
        onConnected = nil
        onSessionUpdate = nil
        let clientToTerminate = client
        let sessionToClose = sessionId
        client = nil
        sessionId = nil
        isConnected = false
        Task {
            // if let clientToTerminate, let sessionToClose {
                // _ = try? await clientToTerminate.closeSession(sessionId: sessionToClose)
            // }
            await clientToTerminate?.terminate()
        }
    }

    func stopStreaming() {
        guard let client, let sessionId else { return }
        isProcessing = false
        Task {
            try? await client.cancelSession(sessionId: sessionId)
        }
    }

    func send(content: [ContentBlock]) {
        guard !content.isEmpty else { return }
        guard let client, let sessionId else {
            error = "Not connected"
            return
        }

        isProcessing = true

        Task {
            do {
                _ = try await client.sendPrompt(sessionId: sessionId, content: content)
                isProcessing = false
                await onTurnComplete?()
            } catch {
                isProcessing = false
                self.error = error.localizedDescription
            }
        }
    }

    func fetchSessionTitle() async -> String? {
        guard let client, let sessionId else { return nil }
        do {
            let response = try await client.listSessions(cwd: workingDirectory)
            return response.sessions.first(where: { $0.sessionId == sessionId })?.title
        } catch {
            return nil
        }
    }

    func applyModel(_ newModel: String) {
        model = newModel
        guard let client, let sessionId, !newModel.isEmpty else { return }
        Task {
            try? await client.setConfigOption(
                sessionId: sessionId,
                configId: SessionConfigId("model"),
                value: SessionConfigValueId(newModel)
            )
        }
    }

    func applyPermissionMode(_ mode: PermissionMode) {
        permissionMode = mode
        guard let client, let sessionId else { return }
        let value = mode.configValue(for: provider)
        Task {
            try? await client.setConfigOption(
                sessionId: sessionId,
                configId: SessionConfigId("mode"),
                value: SessionConfigValueId(value)
            )
        }
    }

    // MARK: - Internal Setters

    func setClient(_ client: Client?) {
        self.client = client
    }

    func setSessionId(_ id: SessionId?) {
        self.sessionId = id
    }

    func setWorkingDirectory(_ dir: String) {
        self.workingDirectory = dir
    }
}
