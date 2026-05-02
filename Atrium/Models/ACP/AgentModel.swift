import Foundation

/// One selectable model surfaced by an ACP agent. Used to be a hardcoded
/// enum; now built from the live `models` field of `newSession` responses
/// and cached in `ModelCatalog`.
struct AgentModel: Codable, Hashable, Identifiable {
    let rawValue: String
    let name: String
    let provider: AgentProvider

    var id: String { rawValue }

    var imageName: String {
        ProviderStyle.symbolName(forProviderName: provider.rawValue)
    }
}
