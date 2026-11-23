import Foundation

/// A background shell session currently running under one of a host's agents.
public nonisolated struct WireBackgroundSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: AgentProvider
    /// The Atrium task ID (`"<provider>:<sessionID>"`) that started it.
    public var taskID: String
    /// The title of the task that started it.
    public var taskTitle: String
    /// Agent-provided name or description, or a concise summary of the command.
    public var title: String
    /// The shell command running in the background.
    public var command: String
    /// Working directory where the background session runs.
    public var directory: String
    /// When the background session started, if known.
    public var startedAt: Date?
    /// Whether live output can be streamed for this session.
    public var hasOutput: Bool

    /// What lists show it as: the title of the chat that started it, else its own.
    public var chatTitle: String { taskTitle.isEmpty ? title : taskTitle }

    public init(
        id: String,
        provider: AgentProvider,
        taskID: String,
        taskTitle: String,
        title: String,
        command: String,
        directory: String,
        startedAt: Date? = nil,
        hasOutput: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.title = title
        self.command = command
        self.directory = directory
        self.startedAt = startedAt
        self.hasOutput = hasOutput
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        taskID = container.lenient(.taskID, or: "")
        taskTitle = container.lenient(.taskTitle, or: "")
        title = container.lenient(.title, or: "")
        command = container.lenient(.command, or: "")
        directory = container.lenient(.directory, or: "")
        startedAt = container.lenient(.startedAt, or: nil)
        hasOutput = container.lenient(.hasOutput, or: false)
    }
}
