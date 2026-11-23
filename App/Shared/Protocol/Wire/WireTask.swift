import Foundation

/// One row of the Mac sidebar. Sections and ordering are derived from these
/// fields on the companion with the same rules the Mac uses.
public nonisolated struct WireTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var provider: AgentProvider
    public var status: AgentThreadStatus
    public var projectName: String
    /// The checkout the task works in, on the host.
    public var path: String
    /// Home-relative path of the checkout, for display.
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
    /// How freely the agent acts without asking, when known.
    public var permissionMode: PermissionMode?
    /// Modes the chat can switch to only by restarting it, which ends a running turn.
    public var permissionModesNeedingRestart: [PermissionMode]?
    /// How much of its model's context the conversation uses, when its provider says.
    public var contextUsage: WireContextUsage?
    public var interactions: [AgentInteraction]
    /// The checkout the agent works in, when it's in a Git repository: the one
    /// it last changed files in, or else where it runs commands.
    public var checkout: TaskCheckout?
    /// The checkouts of its project the agent changed files in, the most
    /// recently changed first, one for each repository. Nil from a host that
    /// doesn't say.
    public var changedCheckouts: [TaskCheckout]?
    /// Pull requests opened from the branches it worked on, or linked by hand.
    public var pullRequests: [PullRequest]
    /// Who started it for work they handed it, or the session a subagent or side chat belongs to.
    public var origin: WireTaskOrigin?
    /// The prompt waiting for the agent's turn to end.
    public var queuedPrompt: QueuedPrompt?

    public init(
        id: String,
        title: String,
        provider: AgentProvider,
        status: AgentThreadStatus,
        projectName: String,
        path: String,
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
        permissionMode: PermissionMode? = nil,
        permissionModesNeedingRestart: [PermissionMode]? = nil,
        contextUsage: WireContextUsage? = nil,
        interactions: [AgentInteraction] = [],
        checkout: TaskCheckout? = nil,
        changedCheckouts: [TaskCheckout]? = nil,
        pullRequests: [PullRequest] = [],
        origin: WireTaskOrigin? = nil,
        queuedPrompt: QueuedPrompt? = nil
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.status = status
        self.projectName = projectName
        self.path = path
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
        self.permissionMode = permissionMode
        self.permissionModesNeedingRestart = permissionModesNeedingRestart
        self.contextUsage = contextUsage
        self.interactions = interactions
        self.checkout = checkout
        self.changedCheckouts = changedCheckouts
        self.pullRequests = pullRequests
        self.origin = origin
        self.queuedPrompt = queuedPrompt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        title = container.lenient(.title, or: "")
        status = container.lenient(.status, or: .unknown)
        projectName = container.lenient(.projectName, or: "")
        path = container.lenient(.path, or: "")
        directory = container.lenient(.directory, or: "")
        workspaceID = container.lenient(.workspaceID, or: nil)
        updatedAt = container.lenient(.updatedAt, or: .distantPast)
        hasUnreadResult = container.lenient(.hasUnreadResult, or: false)
        isSettled = container.lenient(.isSettled, or: false)
        snoozedUntil = container.lenient(.snoozedUntil, or: nil)
        supportsDeletion = container.lenient(.supportsDeletion, or: false)
        actions = container.lenient(.actions, or: [])
        model = container.lenient(.model, or: nil)
        reasoningEffort = container.lenient(.reasoningEffort, or: nil)
        isFastMode = container.lenient(.isFastMode, or: nil)
        permissionMode = container.lenient(.permissionMode, or: nil)
        permissionModesNeedingRestart = container.lenient(.permissionModesNeedingRestart, or: nil)
        contextUsage = container.lenient(.contextUsage, or: nil)
        interactions = container.lenient(.interactions, or: [])
        checkout = container.lenient(.checkout, or: nil)
        changedCheckouts = container.lenient(.changedCheckouts, or: nil)
        pullRequests = container.lenient(.pullRequests, or: [])
        origin = container.lenient(.origin, or: nil)
        queuedPrompt = container.lenient(.queuedPrompt, or: nil)
    }

    public var isSnoozed: Bool { snoozedUntil != nil && !isSettled }

    public static func newestFirst(_ lhs: WireTask, _ rhs: WireTask) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
