import Foundation

/// A background shell session currently running under one of a host's agents.
nonisolated struct WireBackgroundSession: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var provider: AgentProvider
    /// The Atrium task ID (`"<provider>:<sessionID>"`) that started it.
    var taskID: String
    /// The title of the task that started it.
    var taskTitle: String
    /// Agent-provided name or description, or a concise summary of the command.
    var title: String
    /// The shell command running in the background.
    var command: String
    /// Working directory where the background session runs.
    var directory: String
    /// When the background session started, if known.
    var startedAt: Date?

    /// What lists show it as: the title of the chat that started it, else its own.
    var chatTitle: String { taskTitle.isEmpty ? title : taskTitle }

    init(
        id: String,
        provider: AgentProvider,
        taskID: String,
        taskTitle: String,
        title: String,
        command: String,
        directory: String,
        startedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.title = title
        self.command = command
        self.directory = directory
        self.startedAt = startedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        taskID = container.lenient(.taskID, or: "")
        taskTitle = container.lenient(.taskTitle, or: "")
        title = container.lenient(.title, or: "")
        command = container.lenient(.command, or: "")
        directory = container.lenient(.directory, or: "")
        startedAt = container.lenient(.startedAt, or: nil)
    }
}
