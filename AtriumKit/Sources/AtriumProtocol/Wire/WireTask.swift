import Foundation

/// One row of the Mac sidebar. Sections and ordering are derived from these
/// fields on the companion with the same rules the Mac uses.
public nonisolated struct WireTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var provider: AgentProvider
    public var status: AgentThreadStatus
    public var projectName: String
    /// Home-relative path of the checkout the task works in.
    public var directory: String
    /// The Atrium project the task belongs to, when one exists on the Mac.
    public var workspaceID: UUID?
    public var updatedAt: Date
    public var hasUnreadResult: Bool
    public var isSettled: Bool
    public var snoozedUntil: Date?
    public var supportsDeletion: Bool
    /// Actions the Mac currently allows, so the companion never offers one it would reject.
    public var actions: TaskActions
    /// The model the agent last ran with and its reasoning effort, when known.
    public var model: String?
    public var reasoningEffort: String?
    /// Whether the agent runs in fast mode, when its provider has one and it's known.
    public var isFastMode: Bool?
    public var interactions: [AgentInteraction] = []
    /// The checkout the agent works in, when it's in a Git repository.
    public var checkout: TaskCheckout? = nil

    public init(
        id: String,
        title: String,
        provider: AgentProvider,
        status: AgentThreadStatus,
        projectName: String,
        directory: String,
        workspaceID: UUID? = nil,
        updatedAt: Date,
        hasUnreadResult: Bool,
        isSettled: Bool,
        snoozedUntil: Date? = nil,
        supportsDeletion: Bool,
        actions: TaskActions,
        model: String? = nil,
        reasoningEffort: String? = nil,
        isFastMode: Bool? = nil,
        interactions: [AgentInteraction] = [],
        checkout: TaskCheckout? = nil
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.status = status
        self.projectName = projectName
        self.directory = directory
        self.workspaceID = workspaceID
        self.updatedAt = updatedAt
        self.hasUnreadResult = hasUnreadResult
        self.isSettled = isSettled
        self.snoozedUntil = snoozedUntil
        self.supportsDeletion = supportsDeletion
        self.actions = actions
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isFastMode = isFastMode
        self.interactions = interactions
        self.checkout = checkout
    }

    public var isSnoozed: Bool { snoozedUntil != nil && !isSettled }

    public static func newestFirst(_ lhs: WireTask, _ rhs: WireTask) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
