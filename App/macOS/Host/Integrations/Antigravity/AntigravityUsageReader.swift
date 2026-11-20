import AtriumProtocol
import Foundation

/// The plan Antigravity's sign-in has, from a short-lived server of its own,
/// so Settings stays apart from the chats' server. ACP reports no usage.
@MainActor
enum AntigravityUsageReader {
    static func read() async throws -> AgentUsageSnapshot {
        let connection = AntigravityConnection()
        defer { connection.stop() }
        try await connection.start()
        let reply: [String: Any]
        do {
            reply = try await connection.setup()
        } catch let error as AntigravityError where error.message.localizedStandardContains("authentication required") {
            return AgentUsageSnapshot(status: "Not signed in", usageMessage: "Sign in using the Antigravity CLI.")
        }
        let tier = ((reply["_meta"] as? [String: Any])?["antigravity"] as? [String: Any])?["tier"] as? [String: Any]
        return AgentUsageSnapshot(status: "Signed in", plan: tier?["name"] as? String, usageMessage: "Antigravity doesn’t report usage to other apps.")
    }
}
