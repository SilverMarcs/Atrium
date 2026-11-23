import Observation
import OSLog

@MainActor
@Observable
final class AgentUsageModel {
    private(set) var snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")

    func refresh(_ provider: AgentProvider, read: (AgentProvider) async throws -> AgentUsageSnapshot) async {
        snapshot = AgentUsageSnapshot(status: "Loading…", usageMessage: "Loading…")
        do {
            let result = try await read(provider)
            try Task.checkCancellation()
            snapshot = result
        } catch {
            guard !Task.isCancelled else { return }
            Logger(subsystem: "Atrium", category: "AgentUsage").error("\(provider.rawValue, privacy: .public) account read failed: \(error.localizedDescription, privacy: .public)")
            snapshot = AgentUsageSnapshot(status: "Unavailable")
        }
    }
}
