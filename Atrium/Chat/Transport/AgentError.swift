import Foundation

struct AgentError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
