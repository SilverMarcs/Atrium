import Foundation

public nonisolated enum HostEvent: Codable, Sendable {
    /// The first message on every connection, before authentication.
    case hello(HostHello)
    case tasks(WireTasksSnapshot)
    case tasksChanged(WireTasksDelta)
    case transcript(taskID: String, messages: [TranscriptMessage])
    case transcriptChanged(taskID: String, delta: WireTranscriptDelta)
    /// The host couldn't load a task's conversation.
    case transcriptUnavailable(taskID: String, message: String)
    case terminal(taskID: String, frame: WireTerminalFrame)
    case terminalUnavailable(taskID: String, message: String)
    case git(GitScope, repositories: [GitRepositoryStatus])
    case commands(workspaceID: UUID, commands: [WireCommand])
    /// The entries of a followed folder, whenever they change.
    case directory(workspaceID: UUID, path: String, entries: [FileEntry])
    /// A followed file changed on the host.
    case fileChanged(workspaceID: UUID, path: String)
    case remoteAccess(WireRemoteAccess)
    /// An event this client doesn't know, from a newer host.
    case unknown
}

/// Who a host is. Clients that are older than the host's protocol can tell
/// their user to update instead of failing quietly.
public nonisolated struct HostHello: Codable, Sendable, Equatable {
    public var hostID: String
    public var hostName: String
    public var protocolVersion: Int
    /// The host's home folder, which paths are abbreviated against for display.
    public var homeDirectory: String

    public init(hostID: String, hostName: String, protocolVersion: Int, homeDirectory: String) {
        self.hostID = hostID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.homeDirectory = homeDirectory
    }
}
