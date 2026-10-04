import Foundation

enum ToolStatus: String, Codable, Sendable {
    case pending, inProgress, completed, failed
}
