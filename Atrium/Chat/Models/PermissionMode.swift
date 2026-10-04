import Foundation

struct PermissionMode: Identifiable, Codable, Sendable {
    let rawValue: String
    let label: String
    let systemImage: String
    let description: String

    var id: String { rawValue }
}
