import Foundation

struct AgentThread: Identifiable, Codable, Sendable, Equatable {
    let sessionID: String
    let provider: AgentProvider
    var title: String
    var directory: String
    var updatedAt: Date
    var status: AgentThreadStatus
    /// A saved provider name takes precedence over a terminal title or prompt preview.
    var hasProviderTitle = false
    var readState: AgentReadState?
    var hasUnreadResult = false
    /// Original project identity, independent of a provider relocating into a worktree.
    var projectDirectory: String?

    nonisolated var id: String { "\(provider.rawValue):\(sessionID)" }
    var projectName: String { URL(fileURLWithPath: projectDirectory ?? directory).lastPathComponent }
    var needsAttention: Bool { status == .processing || status == .waiting || hasUnreadResult }

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
