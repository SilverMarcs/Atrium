import Foundation

nonisolated enum CompanionRequest: Codable, Sendable {
    /// Trades the one-time secret from the Mac's pairing QR code for a long-lived device token.
    case pair(secret: String, device: CompanionDevice)
    case authenticate(token: String, deviceID: UUID)
    /// Whether this companion is in the foreground, for routing task alerts.
    case activity(CompanionActivity)
    /// Where the Mac sends this phone's task alerts. Sent after each authentication.
    case registerPush(CompanionPushRegistration)
    case subscribe(CompanionTopic)
    case unsubscribe(CompanionTopic)
    /// Fetches a custom project icon once; icons are referenced by key elsewhere.
    case icon(key: String)
    case refreshTasks
    case task(id: String, action: CompanionTaskAction)
    case compose(provider: AgentProvider, workspaceID: UUID)
    /// Sends a prompt to the task's agent, as if typed on the Mac, with any
    /// attached images as JPEG data.
    case prompt(taskID: String, text: String, images: [Data])
    /// Stops the agent's current turn.
    case interrupt(taskID: String)
    case updateScratchpad(workspaceID: UUID, text: String)
    case git(workspaceID: UUID, action: CompanionGitAction)
    case gitDiff(workspaceID: UUID, path: String, isStaged: Bool)
    case command(workspaceID: UUID, commandID: UUID, action: CompanionCommandAction)
}
