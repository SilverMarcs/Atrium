import AtriumClient
import AtriumProtocol
import Foundation

// What the command line reports, kept apart from the wire types so its JSON
// stays stable as the protocol grows.

struct SessionJSON: Encodable, Equatable {
    var id: String
    var title: String
    var provider: String
    /// processing, waiting (needs input), done, idle, failed, stopped or offline.
    var status: String
    var project: ProjectRef?
    var directory: String
    var updatedAt: Date
    var unread: Bool
    var settled: Bool
    var snoozedUntil: Date?
    var model: String?
    var reasoningEffort: String?
    var fastMode: Bool?
    /// What the host allows right now, such as prompt or interrupt.
    var actions: [String]
    /// Questions and approvals waiting for an answer.
    var interactions: [InteractionJSON]

    struct ProjectRef: Encodable, Equatable {
        var id: UUID
        var name: String
    }

    init(_ task: WireTask, workspace: WireWorkspace?) {
        id = task.id
        title = task.title
        provider = task.provider.rawValue
        status = task.status.name
        project = workspace.map { ProjectRef(id: $0.id, name: $0.name) }
        directory = task.directory
        updatedAt = task.updatedAt
        unread = task.hasUnreadResult
        settled = task.isSettled
        snoozedUntil = task.snoozedUntil
        model = task.model
        reasoningEffort = task.reasoningEffort
        fastMode = task.isFastMode
        actions = task.actions.names
        interactions = task.interactions.map(InteractionJSON.init)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, provider, status, project, directory, updatedAt, unread, settled, snoozedUntil
        case model, reasoningEffort, fastMode, actions, interactions
    }

    // Unknown values are null rather than missing, so every session has the same keys.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(provider, forKey: .provider)
        try container.encode(status, forKey: .status)
        try container.encode(project, forKey: .project)
        try container.encode(directory, forKey: .directory)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(unread, forKey: .unread)
        try container.encode(settled, forKey: .settled)
        try container.encode(snoozedUntil, forKey: .snoozedUntil)
        try container.encode(model, forKey: .model)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(fastMode, forKey: .fastMode)
        try container.encode(actions, forKey: .actions)
        try container.encode(interactions, forKey: .interactions)
    }
}

struct InteractionJSON: Encodable, Equatable {
    var id: String
    var title: String
    var detail: String
    /// False when the agent asks something only its terminal can answer.
    var canRespond: Bool
    var questions: [Question]

    struct Question: Encodable, Equatable {
        var id: String
        var title: String
        var options: [String]
        var optionDescriptions: [String: String]
        var allowsMultiple: Bool
        var isSecret: Bool
    }

    init(_ interaction: AgentInteraction) {
        id = interaction.id
        title = interaction.title
        detail = interaction.detail
        canRespond = interaction.supportsResponse
        questions = interaction.questions.map {
            Question(
                id: $0.id, title: $0.title, options: $0.options, optionDescriptions: $0.optionDescriptions,
                allowsMultiple: $0.allowsMultiple, isSecret: $0.isSecret
            )
        }
    }
}

struct MessageJSON: Encodable, Equatable {
    var id: String
    var role: String
    /// The message's text blocks, joined by blank lines.
    var text: String
    /// Text and tool-call runs in the order the agent produced them.
    var blocks: [Block]
    var imageCount: Int
    /// Sent while the agent was working, so it joined that turn.
    var steer: Bool

    struct Block: Encodable, Equatable {
        var type: String
        var text: String?
        var toolCalls: Int?
    }

    init(_ message: TranscriptMessage) {
        id = message.id
        role = message.role.rawValue
        text = message.blocks.compactMap(\.text).joined(separator: "\n\n")
        blocks = message.blocks.map { block in
            switch block {
            case .text(let text, _): Block(type: "text", text: text)
            case .tools(let count, _): Block(type: "tools", toolCalls: count)
            }
        }
        imageCount = message.images?.count ?? 0
        steer = message.isSteer
    }
}

struct ProjectJSON: Encodable {
    var id: UUID
    var name: String
    var path: String
    var directory: String
    var projectType: String
    var hasRunningCommand: Bool

    init(_ workspace: WireWorkspace) {
        id = workspace.id
        name = workspace.name
        path = workspace.path
        directory = workspace.directory
        projectType = workspace.projectType
        hasRunningCommand = workspace.hasRunningCommand
    }
}

struct ProviderJSON: Encodable {
    var provider: String
    var enabled: Bool
    var error: String?
    var models: [Model]?

    struct Model: Encodable {
        var id: String
        var name: String
        var summary: String
        var reasoningEfforts: [String]
        var supportsFastMode: Bool
    }

    init(_ provider: WireProvider) {
        self.provider = provider.provider.rawValue
        enabled = provider.isEnabled
        error = provider.error
        models = provider.models?.map {
            Model(id: $0.id, name: $0.name, summary: $0.summary, reasoningEfforts: $0.reasoningEfforts, supportsFastMode: $0.supportsFastMode)
        }
    }
}

struct HostJSON: Encodable {
    var id: String
    var name: String
    var hostName: String
}

extension AgentThreadStatus {
    /// A stable machine name; the raw value is what people see.
    var name: String {
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

    init?(name: String) {
        guard let status = Self.allNames.first(where: { $0.name == name }) else { return nil }
        self = status
    }

    static let allNames: [AgentThreadStatus] = [.processing, .waiting, .done, .idle, .failed, .stopped, .unknown]
}

extension TaskActions {
    var names: [String] {
        let all: [(TaskActions, String)] = [
            (.prompt, "prompt"), (.interrupt, "interrupt"), (.selectModel, "configure"), (.editMessage, "edit"),
            (.rename, "rename"), (.fork, "fork"), (.settle, "settle"), (.restore, "restore"),
            (.snooze, "snooze"), (.unsnooze, "unsnooze"), (.markRead, "mark-read"), (.markUnread, "mark-unread"),
            (.delete, "delete"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}
