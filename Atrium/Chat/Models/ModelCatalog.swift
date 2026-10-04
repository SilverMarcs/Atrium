import Foundation
import Observation

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()
    private var values: [AgentProvider: AgentCatalog] = [:]
    private var refreshing: Set<AgentProvider> = []

    func models(for provider: AgentProvider) -> [AgentModel] { values[provider]?.models ?? [] }
    func defaultModel(for provider: AgentProvider) -> AgentModel? {
        models(for: provider).first { $0.rawValue == values[provider]?.defaultModel } ?? models(for: provider).first(where: \.isDefault) ?? models(for: provider).first
    }
    func permissionModes(for provider: AgentProvider) -> [PermissionMode] { values[provider]?.permissionModes ?? [] }
    func ingest(_ catalog: AgentCatalog, provider: AgentProvider) { values[provider] = catalog }
    func bootstrapIfNeeded() {
        for provider in AgentProvider.allCases where models(for: provider).isEmpty { refresh(provider) }
    }

    private func refresh(_ provider: AgentProvider) {
        guard !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        let backend = AgentBackendFactory.make(provider)
        Task {
            defer { backend.close(); refreshing.remove(provider) }
            do { values[provider] = try await backend.catalog() }
            catch { print("[Models] \(error.localizedDescription)") }
        }
    }
}
