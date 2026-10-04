import Foundation

public struct WireSessionMeta: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var workspaceId: UUID
    public var title: String
    public var date: Date
    public var turnCount: Int
    public var isConnecting: Bool
    public var isProcessing: Bool
    public var isArchived: Bool
    public var providerName: String
    public var isActive: Bool
    public var hasNotification: Bool

    public init(id: UUID, workspaceId: UUID, title: String, date: Date, turnCount: Int, isProcessing: Bool, isArchived: Bool, providerName: String, isActive: Bool, hasNotification: Bool, isConnecting: Bool = false) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.date = date
        self.turnCount = turnCount
        self.isConnecting = isConnecting
        self.isProcessing = isProcessing
        self.isArchived = isArchived
        self.providerName = providerName
        self.isActive = isActive
        self.hasNotification = hasNotification
    }
}
