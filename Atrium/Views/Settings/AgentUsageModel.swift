import AtriumProtocol
import Observation

@MainActor
@Observable
final class AgentUsageModel {
    private(set) var snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")

    func refresh(_ provider: AgentProvider) async {
        snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")
        do {
            let result: AgentUsageSnapshot
            switch provider {
            case .codex:
                // A separate, short-lived connection keeps Settings independent of
                // enabled integrations and can't interrupt an active conversation.
                let reader = CodexAgentAdapter()
                defer { reader.setEnabled(false) }
                result = try await reader.usageSnapshot()
            case .claude:
                result = try await ClaudeUsageReader.read()
            }
            try Task.checkCancellation()
            snapshot = result
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = AgentUsageSnapshot(status: "Unavailable")
        }
    }
}
