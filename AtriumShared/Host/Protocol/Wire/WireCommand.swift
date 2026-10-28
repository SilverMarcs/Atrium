import Foundation

/// A saved command from the Mac's Commands inspector.
nonisolated struct WireCommand: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    /// Nil for a plain terminal slot with nothing to run.
    var script: String?
    var isRunning: Bool
    var isDefault: Bool

    var canRun: Bool { !(script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}
