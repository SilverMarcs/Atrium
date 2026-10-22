import Foundation

struct ThreadActivity: Codable {
    var date: Date
    private var status: AgentThreadStatus
    private var unread = false
    private var readRevision: String?

    init(thread: AgentThread) {
        date = thread.updatedAt
        status = thread.status
    }

    mutating func update(_ source: AgentThread, isViewed: Bool, now: Date = .now) -> AgentThread {
        var thread = source
        date = max(date, source.updatedAt)
        if thread.status == .idle, [.processing, .done].contains(status) {
            thread.status = .done
        }
        let completed = thread.status == .done && status != .done
        let beganWorking = thread.status == .processing && status != .processing
        if beganWorking && status != .waiting { date = max(date, now) }
        if completed { unread = true }
        if beganWorking { unread = false }
        if thread.status != .unknown { status = thread.status }
        thread.updatedAt = date
        if isViewed { markRead(thread) }
        thread.hasUnreadResult = thread.readState.map { $0.isUnread && $0.revision != readRevision } ?? unread
        return thread
    }

    mutating func markRead(_ thread: AgentThread) {
        unread = false
        readRevision = thread.readState?.revision
    }

    mutating func clearReadRevision() {
        readRevision = nil
    }
}
