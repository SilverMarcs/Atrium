import Foundation

enum PlanEntryStatus: String, Codable, Sendable {
    case pending, inProgress, completed, cancelled
}
