import Foundation

struct AgentCatalog: Sendable {
    let models: [AgentModel]
    let permissionModes: [PermissionMode]
    let defaultModel: String
    let defaultReasoningLevel: String
}
