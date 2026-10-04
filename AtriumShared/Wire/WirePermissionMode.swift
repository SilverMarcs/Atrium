import Foundation

public struct WirePermissionMode: Codable, Sendable, Hashable, Identifiable {
    public var rawValue: String
    public var label: String
    public var systemImage: String
    public var description: String

    public var id: String { rawValue }

    public init(rawValue: String, label: String, systemImage: String, description: String) {
        self.rawValue = rawValue
        self.label = label
        self.systemImage = systemImage
        self.description = description
    }
}
