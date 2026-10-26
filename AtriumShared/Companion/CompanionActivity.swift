import Foundation

/// Whether a companion is in the foreground and which task it shows. Sent only
/// when either changes; the Mac decides which device gets alerts from it.
nonisolated struct CompanionActivity: Codable, Sendable {
    var isActive: Bool
    var taskID: String?
}
