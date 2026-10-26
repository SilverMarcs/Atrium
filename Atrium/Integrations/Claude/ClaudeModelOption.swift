import Foundation

/// A row of Claude's model picker, as its SDK `initialize` response lists it.
struct ClaudeModelOption: Decodable, Sendable {
    let value: String
    let resolvedModel: String?
    let displayName: String
    let description: String
    let supportsEffort: Bool?
    let supportedEffortLevels: [String]?
    let supportsFastMode: Bool?

    /// Fast mode also needs the account's organization to allow it.
    func model(allowingFastMode: Bool) -> AgentModel {
        AgentModel(
            id: value,
            resolvedID: resolvedModel ?? value,
            name: displayName,
            summary: description,
            reasoningEfforts: supportsEffort == true ? supportedEffortLevels ?? [] : [],
            supportsFastMode: allowingFastMode && supportsFastMode == true
        )
    }
}
