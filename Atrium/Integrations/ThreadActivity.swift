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
        if thread.status == .idle, [.processing, .done].contains(status) {
            thread.status = .done
        }
        let completed = thread.status == .done && status != .done
        let beganWorking = thread.status == .processing && status != .processing
        // Provider timestamps advance on every transcript write, so a running task keeps its place until it finishes.
        if completed || (beganWorking && status != .waiting) {
            date = max(date, now)
        } else if ![.processing, .waiting].contains(thread.status) {
            date = max(date, source.updatedAt)
        }
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

    mutating func markUnread() {
        unread = true
    }

    mutating func resurface(now: Date = .now, markUnread: Bool) {
        date = max(date, now)
        if markUnread { unread = true }
    }

    mutating func clearReadRevision() {
        readRevision = nil
    }
}
