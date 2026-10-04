import Foundation

struct AgentSettings: Sendable {
    let directory: String
    var sessionID: String?
    var model: String
    var reasoningLevel: String
    var permissionMode: String
}
