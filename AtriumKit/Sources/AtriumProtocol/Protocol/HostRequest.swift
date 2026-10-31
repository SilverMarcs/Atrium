import Foundation

public nonisolated enum HostRequest: Codable, Sendable {
    /// Trades the one-time secret from a host's pairing link for a long-lived device token.
    case pair(secret: String, device: ClientDevice)
    case authenticate(token: String, deviceID: UUID)
    /// Whether this client is in the foreground and which task it shows.
    case activity(ClientActivity)
    /// Where the host sends this phone's task alerts. Sent after each authentication.
    case registerPush(PushRegistration)
    case subscribe(HostTopic)
    case unsubscribe(HostTopic)
    /// Fetches a custom project icon once; icons are referenced by key elsewhere.
    case icon(key: String)
    /// Fetches a page an agent showed in a task's transcript, by its `TranscriptPage.key`.
    case page(taskID: String, key: String)
    /// Fetches an image an agent showed in a task's transcript, by the path it
    /// wrote: absolute, `~/`, or relative to the task's directory. Images wider
    /// or taller than `maxPixelSize` come back scaled down to fit it.
    case image(taskID: String, path: String, maxPixelSize: Int)
    case refreshTasks
    case task(id: String, action: TaskAction)
    case compose(provider: AgentProvider, workspaceID: UUID, settings: TaskStartSettings? = nil)
    /// Sends a prompt to the task's agent, with any attached images as JPEG data.
    case prompt(taskID: String, text: String, images: [Data])
    /// Stops the agent's current turn.
    case interrupt(taskID: String)
    case terminal(taskID: String, action: TerminalAction)
    /// Adds a folder on the host as a project. Only the host itself may.
    case addWorkspace(path: String)
    case workspace(id: UUID, action: WorkspaceAction)
    case command(workspaceID: UUID, commandID: UUID, action: CommandAction)
    case git(workspaceID: UUID, repository: URL, operation: GitOperation)
    case files(workspaceID: UUID, request: FileRequest)
    /// Turns an agent integration on or off. Only the host itself may.
    case setProviderEnabled(AgentProvider, Bool)
    /// Turns reaching the host through the relay on or off. Only the host itself may.
    case setRemoteAccess(Bool)
    /// Revokes a paired device and disconnects it. Only the host itself may.
    case forgetDevice(UUID)
    /// A request this host doesn't know, from a newer client.
    case unsupported
}

public nonisolated enum TaskAction: Codable, Sendable {
    case settle
    case restore
    case snooze(until: Date)
    case unsnooze
    /// Acknowledges the result, just like opening the task on the host.
    case viewed
    case markRead
    case markUnread
    case rename(title: String)
    case fork
    case delete
    /// Switches the model, and its reasoning effort when it has one, for the
    /// agent's next turns. The model is one its provider lists.
    case selectModel(id: String, reasoningEffort: String?)
    /// Turns fast mode on or off for the agent's next turns.
    case setFastMode(Bool)
    /// Removes this prompt and later conversation, keeping files unchanged.
    case rewind(messageID: String)
    case respond(interactionID: String, decision: AgentDecision)
}

public nonisolated enum WorkspaceAction: Codable, Sendable {
    /// Names the project; an empty name goes back to its folder's.
    case rename(String)
    case setScratchpad(String)
    case setProjectType(String)
    case detectProjectType
    /// Copies an image file on the host as the project's icon. Only the host itself may.
    case setIcon(path: String)
    case clearIcon
    /// Moves the project to a position in the host's project order.
    case move(toIndex: Int)
    /// Removes the project from the host, leaving its folder alone. Only the host itself may.
    case remove
    case addCommand(title: String, script: String?)
}

public nonisolated enum CommandAction: Codable, Sendable {
    case run
    case stop
    case update(title: String, script: String?)
    case setDefault
    case move(toIndex: Int)
    case remove
}
