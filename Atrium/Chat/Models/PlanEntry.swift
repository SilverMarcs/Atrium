import Foundation

struct PlanEntry: Codable, Sendable {
    let content: String
    let status: PlanEntryStatus
}
