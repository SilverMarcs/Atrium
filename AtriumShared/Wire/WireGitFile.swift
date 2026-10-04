import Foundation

public struct WireGitFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var status: String

    public var id: String { path }

    public init(path: String, name: String, status: String) {
        self.path = path
        self.name = name
        self.status = status
    }
}
