import Foundation

/// A saved command from the Mac's Commands inspector.
public nonisolated struct WireCommand: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// Nil for a plain terminal slot with nothing to run.
    public var script: String?
    public var isRunning: Bool
    public var isDefault: Bool

    public init(id: UUID, title: String, script: String? = nil, isRunning: Bool, isDefault: Bool) {
        self.id = id
        self.title = title
        self.script = script
        self.isRunning = isRunning
        self.isDefault = isDefault
    }

    public var canRun: Bool { !(script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}
