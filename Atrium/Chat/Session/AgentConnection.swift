import Foundation

struct AgentConnection: Sendable {
    let sessionID: String
    let catalog: AgentCatalog
    let permissionMode: String
    let model: String
    let reasoningLevel: String
}
