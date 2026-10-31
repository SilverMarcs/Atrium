import AtriumProtocol
import Foundation

struct AgentThread: Identifiable, Codable, Sendable, Equatable {
    let sessionID: String
    let provider: AgentProvider
    var title: String
    var directory: String
    var updatedAt: Date
    var status: AgentThreadStatus
    /// Only provider-confirmed main tasks may alert. Older retained rows have no classification yet.
    var isMainTask: Bool?
    /// A saved provider name takes precedence over a terminal title or prompt preview.
    var hasProviderTitle = false
    var readState: AgentReadState?
    var hasUnreadResult = false
    /// Original project identity, independent of a provider relocating into a worktree.
    var projectDirectory: String?
    /// The model the agent last ran with and its reasoning effort, when the provider records them.
    var model: String?
    var reasoningEffort: String?
    /// Whether the agent runs in fast mode, when the provider has one and reports it.
    var isFastMode: Bool?
    /// For a subagent the provider runs itself, the session whose agent started
    /// it. Atrium shows it under that session, to read but not to prompt:
    /// neither provider takes input for a subagent from anyone but its agent.
    var parentSessionID: String?

    nonisolated var id: String { "\(provider.rawValue):\(sessionID)" }
    var projectName: String { URL(fileURLWithPath: projectDirectory ?? directory).lastPathComponent }
    var needsAttention: Bool { status == .processing || status == .waiting || hasUnreadResult }
    var isSubagent: Bool { parentSessionID != nil }
    /// The ID of the session that started this one as a subagent.
    var parentID: String? { parentSessionID.map { "\(provider.rawValue):\($0)" } }

    nonisolated static func newestFirst(_ lhs: AgentThread, _ rhs: AgentThread) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }

    static func unique(_ threads: [AgentThread]) -> [AgentThread] {
        var byID: [String: AgentThread] = [:]
        for thread in threads {
            if let previous = byID[thread.id], previous.updatedAt > thread.updatedAt { continue }
            byID[thread.id] = thread
        }
        return byID.values.sorted(by: newestFirst)
    }
}
