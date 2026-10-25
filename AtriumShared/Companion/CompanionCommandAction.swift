import Foundation

nonisolated enum CompanionCommandAction: Codable, Sendable {
    case run
    case stop
}
