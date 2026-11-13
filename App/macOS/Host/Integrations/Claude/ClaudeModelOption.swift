import AtriumProtocol
import Foundation

/// A row of Claude's model picker, as its SDK `initialize` response lists it.
struct ClaudeModelOption: Decodable, Sendable {
    let value: String
    let resolvedModel: String?
    let displayName: String?
    let description: String?
    let supportsEffort: Bool?
    let supportedEffortLevels: [String]?
    let supportsFastMode: Bool?
    let supportsAutoMode: Bool?

    /// Fast mode also needs the account's organization to allow it, and each
    /// permission mode Claude's settings on this Mac to.
    func model(allowingFastMode: Bool, permissionModes: [PermissionMode]) -> AgentModel {
        AgentModel(
            id: value,
            resolvedID: resolvedModel ?? value,
            name: displayName ?? value,
            summary: description ?? "",
            reasoningEfforts: supportsEffort == true ? supportedEffortLevels ?? [] : [],
            supportsFastMode: allowingFastMode && supportsFastMode == true,
            permissionModes: permissionModes.filter { $0 != .auto || supportsAutoMode == true }
        )
    }
}
