import AtriumProtocol
import Observation
import OSLog

@MainActor
@Observable
final class AgentUsageModel {
    private(set) var snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")

    func refresh(_ provider: AgentProvider, antigravity: () async throws -> AgentUsageSnapshot) async {
        snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")
        do {
            let result: AgentUsageSnapshot
            switch provider {
            case .codex:
                // A separate, short-lived connection keeps Settings independent of
                // enabled integrations and can't interrupt an active conversation.
                let reader = CodexAgentAdapter(bridge: AgentBridgeServer(), instructions: ChatInstructions())
                defer { reader.setEnabled(false) }
                result = try await reader.usageSnapshot()
            case .claude:
                result = try await ClaudeUsageReader.read()
            case .antigravity:
                result = try await antigravity()
            }
            try Task.checkCancellation()
            snapshot = result
        } catch {
            guard !Task.isCancelled else { return }
            Logger(subsystem: "Atrium", category: "AgentUsage").error("\(provider.rawValue, privacy: .public) account read failed: \(error.localizedDescription, privacy: .public)")
            snapshot = AgentUsageSnapshot(status: "Unavailable")
        }
    }
}
