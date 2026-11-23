import Foundation

public nonisolated enum HostEvent: Codable, Sendable {
    /// Who this host is: sent first on every connection, and again whenever its
    /// name or icon changes.
    case hello(HostHello)
    case tasks(WireTasksSnapshot)
    case tasksChanged(WireTasksDelta)
    case transcript(taskID: String, messages: [TranscriptMessage])
    case transcriptChanged(taskID: String, delta: WireTranscriptDelta)
    /// The host couldn't load a task's conversation.
    case transcriptUnavailable(taskID: String, message: String)
    case git(GitScope, repositories: [GitRepositoryStatus])
    case commands(workspaceID: UUID, commands: [WireCommand])
    /// A followed command's output: complete when a client subscribes, then what changed.
    case commandOutput(workspaceID: UUID, commandID: UUID, output: WireCommandOutput)
    /// A followed agent background session's output: complete when a client subscribes, then what changed.
    case backgroundSessionOutput(workspaceID: UUID, sessionID: String, output: WireCommandOutput)
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
    public var hostIcon: HostIcon
    public var protocolVersion: Int
    /// The host's home folder, which paths are abbreviated against for display.
    public var homeDirectory: String

    public init(
        hostID: String,
        hostName: String,
        hostIcon: HostIcon = .default,
        protocolVersion: Int,
        homeDirectory: String
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostIcon = hostIcon
        self.protocolVersion = protocolVersion
        self.homeDirectory = homeDirectory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        hostIcon = (try? container.decodeIfPresent(HostIcon.self, forKey: .hostIcon)) ?? .default
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        homeDirectory = try container.decode(String.self, forKey: .homeDirectory)
    }
}
