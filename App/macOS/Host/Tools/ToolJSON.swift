import Foundation

// What the host's tools report, kept apart from the wire types so agents see
// a small, stable shape as the protocol grows.

nonisolated struct SessionJSON: Encodable {
    var id: String
    var title: String
    var provider: String
    /// processing, waiting (needs an answer), done, idle, failed, stopped or offline.
    var status: String
    var project: ProjectRef?
    var directory: String
    var updatedAt: Date
    var unread: Bool
    var settled: Bool
    var model: String?
    var reasoningEffort: String?
    /// How freely its agent acts without asking: supervised, acceptEdits, auto or fullAccess.
    var permissionMode: String?
    /// A prompt waiting for the agent's turn to end.
    var queuedPrompt: Bool
    /// Questions and approvals waiting for an answer.
    var interactions: [InteractionJSON]
    /// The session this one belongs to: one whose agent started it, or runs it as a subagent.
    var parent: String?
    var subagent: Bool
    /// The device that started it, such as ChatGPT.
    var startedBy: String?

    struct ProjectRef: Encodable {
        var id: UUID
        var name: String
    }

    init(_ task: WireTask, workspace: WireWorkspace?) {
        id = task.id
        title = task.title
        provider = task.provider.rawValue
        status = task.status.toolName
        project = workspace.map { ProjectRef(id: $0.id, name: $0.name) }
        directory = task.directory
        updatedAt = task.updatedAt
        unread = task.hasUnreadResult
        settled = task.isSettled
        model = task.model
        reasoningEffort = task.reasoningEffort
        permissionMode = task.permissionMode?.rawValue
        queuedPrompt = task.queuedPrompt != nil
        interactions = task.interactions.map(InteractionJSON.init)
        parent = task.origin?.parentID
        subagent = task.isSubagent
        startedBy = task.origin?.deviceName
    }
}

nonisolated struct InteractionJSON: Encodable {
    var id: String
    var title: String
    var detail: String
    /// False when only the agent's own interface on the Mac can answer it.
    var canRespond: Bool
    var questions: [Question]

    struct Question: Encodable {
        var id: String
        var title: String
        var options: [String]
        var allowsMultiple: Bool
    }

    init(_ interaction: AgentInteraction) {
        id = interaction.id
        title = interaction.title
        detail = interaction.detail
        // A secret is the user's to give, never another agent's.
        canRespond = interaction.supportsResponse && !SecretRequests.isRequest(interaction.id)
        questions = interaction.questions.map {
            Question(id: $0.id, title: $0.title, options: $0.options, allowsMultiple: $0.allowsMultiple)
        }
    }
}

nonisolated struct MessageJSON: Encodable {
    var id: String
    var role: String
    /// The message's text blocks, joined by blank lines.
    var text: String
    /// Tool calls the agent made in this message.
    var toolCalls: Int
    /// Titles of pages the agent showed.
    var pages: [String]
    /// For a prompt another agent wrote: who.
    var from: String?

    init(_ message: TranscriptMessage) {
        id = message.id
        role = message.role.rawValue
        text = message.blocks.compactMap(\.text).joined(separator: "\n\n")
        toolCalls = message.blocks.reduce(0) { $0 + $1.toolCount }
        pages = message.blocks.compactMap(\.page?.title)
        from = message.relay?.senders.map(\.name).joined(separator: ", ")
    }
}

nonisolated struct ProjectJSON: Encodable {
    var id: UUID
    var name: String
    var directory: String

    init(_ workspace: WireWorkspace) {
        id = workspace.id
        name = workspace.name
        directory = workspace.directory
    }
}

nonisolated struct AgentJSON: Encodable {
    var provider: String
    var available: Bool
    var models: [Model]

    struct Model: Encodable {
        var id: String
        var name: String
        var reasoningEfforts: [String]
        var supportsFastMode: Bool
    }

    init(_ provider: WireProvider) {
        self.provider = provider.provider.rawValue
        available = provider.isAvailable
        models = (provider.models ?? []).map {
            Model(id: $0.id, name: $0.name, reasoningEfforts: $0.reasoningEfforts, supportsFastMode: $0.supportsFastMode)
        }
    }
}

extension AgentThreadStatus {
    /// A stable machine name; the raw value is what people see.
    nonisolated var toolName: String {
        switch self {
        case .processing: "processing"
        case .waiting: "waiting"
        case .done: "done"
        case .idle: "idle"
        case .failed: "failed"
        case .stopped: "stopped"
        case .unknown: "offline"
        }
    }
}
