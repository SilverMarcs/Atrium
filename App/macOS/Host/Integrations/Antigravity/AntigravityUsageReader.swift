import AtriumProtocol
import Foundation

/// Reads the language server's account metadata without opening a conversation.
/// The host owns the connection; reading Settings must never stop its chats.
@MainActor
enum AntigravityUsageReader {
    static func read(connection: AntigravityConnection) async throws -> AgentUsageSnapshot {
        let reply: [String: Any]
        do {
            reply = try await connection.languageServerReply("GetUserStatus", [:], timeout: 5)
        } catch let error as AntigravityError where error.isAuthenticationRequired {
            return AgentUsageSnapshot(status: "Not signed in", usageMessage: "Sign in using the Antigravity CLI.")
        }
        guard let status = reply["userStatus"] as? [String: Any], !status.isEmpty else {
            throw IntegrationError(message: "Antigravity didn’t return account information.")
        }
        let tier = status["userTier"] as? [String: Any]
        let plan = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        return AgentUsageSnapshot(status: "Signed in", plan: tier?["name"] as? String ?? plan?["planName"] as? String,
                                  usageMessage: "View usage in the Antigravity CLI.")
    }
}
