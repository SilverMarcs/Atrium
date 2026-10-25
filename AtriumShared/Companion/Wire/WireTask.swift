import Foundation

/// One row of the Mac sidebar. Sections and ordering are derived from these
/// fields on the companion with the same rules the Mac uses.
nonisolated struct WireTask: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var provider: AgentProvider
    var status: AgentThreadStatus
    var projectName: String
    /// Home-relative path of the checkout the task works in.
    var directory: String
    /// The Atrium project the task belongs to, when one exists on the Mac.
    var workspaceID: UUID?
    var updatedAt: Date
    var hasUnreadResult: Bool
    var isSettled: Bool
    var snoozedUntil: Date?
    var supportsDeletion: Bool
    /// Actions the Mac currently allows, so the companion never offers one it would reject.
    var actions: TaskActions

    var isSnoozed: Bool { snoozedUntil != nil && !isSettled }

    var menuState: TaskMenuState {
        TaskMenuState(
            isSettled: isSettled,
            isSnoozed: snoozedUntil != nil,
            hasUnreadResult: hasUnreadResult,
            supportsDeletion: supportsDeletion,
            allowed: actions
        )
    }

    static func newestFirst(_ lhs: WireTask, _ rhs: WireTask) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
