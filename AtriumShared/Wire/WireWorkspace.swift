import Foundation

public struct WireWorkspace: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var customIconData: Data?
    public var isArchived: Bool
    public var hasActiveChildProcess: Bool
    public var scratchpad: String
    public var sessions: [WireSessionMeta]

    public init(id: UUID, name: String, customIconData: Data?, isArchived: Bool, hasActiveChildProcess: Bool, scratchpad: String, sessions: [WireSessionMeta]) {
        self.id = id
        self.name = name
        self.customIconData = customIconData
        self.isArchived = isArchived
        self.hasActiveChildProcess = hasActiveChildProcess
        self.scratchpad = scratchpad
        self.sessions = sessions
    }
}
