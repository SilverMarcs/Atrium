import Foundation

public struct WireCommand: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var script: String?
    public var isRunning: Bool
    public var isDefault: Bool

    public init(id: UUID, title: String, script: String?, isRunning: Bool, isDefault: Bool) {
        self.id = id
        self.title = title
        self.script = script
        self.isRunning = isRunning
        self.isDefault = isDefault
    }
}
