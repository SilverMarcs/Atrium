import Foundation
import Observation

@Observable
@MainActor
final class Chat: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String = "New Chat"
    var backendSessionID: String?
    var provider: AgentProvider = .codex
    var permissionMode: String = ""
    var model: String = ""
    var reasoningLevel: String = ""
    var date: Date = Date()
    var sortOrder: Int = 0
    var turnCount: Int = 0
    var isArchived: Bool = false

    var usedTokens: Int = 0
    var contextSize: Int = 0
    var plan: [PlanEntry] = []
    var messages: [Message] = []

    @ObservationIgnored
    weak var workspace: Workspace?

    @ObservationIgnored
    var session = AgentSession()

    @ObservationIgnored
    var currentTurnMessage: Message?

    @ObservationIgnored
    var pendingContent: AgentInput?

    var prompt: String = ""
    var pendingAttachments: [ChatAttachment] = []

    var hasNotification: Bool = false

    var isActive: Bool { session.isConnected }
    var permissionModes: [PermissionMode] {
        session.permissionModes.isEmpty ? ModelCatalog.shared.permissionModes(for: provider) : session.permissionModes
    }
    var selectedPermissionMode: PermissionMode? { permissionModes.first { $0.rawValue == permissionMode } }

    init(title: String = "New Chat", provider: AgentProvider = .codex, permissionMode: String = "", model: String? = nil, sortOrder: Int = 0) {
        self.title = title
        self.provider = provider
        self.permissionMode = permissionMode
        self.model = model ?? ModelCatalog.shared.defaultModel(for: provider)?.rawValue ?? ""
        self.reasoningLevel = ""
        self.session.applyModel(self.model)
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, backendSessionID, provider, permissionMode, model, date, sortOrder, turnCount, isArchived
        case usedTokens, contextSize, plan, messages, reasoningLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.backendSessionID = try c.decodeIfPresent(String.self, forKey: .backendSessionID)
        self.provider = try c.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .codex
        self.permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.reasoningLevel = try c.decodeIfPresent(String.self, forKey: .reasoningLevel) ?? ""
        self.date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.usedTokens = try c.decodeIfPresent(Int.self, forKey: .usedTokens) ?? 0
        self.contextSize = try c.decodeIfPresent(Int.self, forKey: .contextSize) ?? 0
        self.plan = try c.decodeIfPresent([PlanEntry].self, forKey: .plan) ?? []
        self.messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        for msg in messages { msg.chat = self }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(backendSessionID, forKey: .backendSessionID)
        try c.encode(provider, forKey: .provider)
        try c.encode(permissionMode, forKey: .permissionMode)
        try c.encode(model, forKey: .model)
        try c.encode(reasoningLevel, forKey: .reasoningLevel)
        try c.encode(date, forKey: .date)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(turnCount, forKey: .turnCount)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(usedTokens, forKey: .usedTokens)
        try c.encode(contextSize, forKey: .contextSize)
        try c.encode(plan, forKey: .plan)
        try c.encode(messages, forKey: .messages)
    }

    static func == (lhs: Chat, rhs: Chat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func scheduleSave() {
        workspace?.store?.scheduleSave()
    }

    func notify(_ reason: String) {
        guard !session.isConnecting else { return }
        guard let workspace else { return }
        hasNotification = true
        AppDelegate.sendChatNotification(
            workspaceTitle: workspace.name,
            body: reason,
            workspaceID: workspace.id,
            chatID: id
        )
    }

    var displayTitle: String {
        if !title.isEmpty, title != "New Chat" {
            return title
        }
        if let lastUserMessage = messages.last(where: { $0.role == .user }), !lastUserMessage.text.isEmpty {
            return String(lastUserMessage.text.prefix(30))
        }
        return title
    }

}
