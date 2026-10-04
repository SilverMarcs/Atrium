import Foundation

public struct WireAgentModel: Codable, Sendable, Hashable, Identifiable {
    public var rawValue: String
    public var name: String
    public var imageName: String
    public var reasoningLevels: [WireReasoningLevel]

    public var id: String { rawValue }

    public init(rawValue: String, name: String, imageName: String, reasoningLevels: [WireReasoningLevel] = []) {
        self.rawValue = rawValue
        self.name = name
        self.imageName = imageName
        self.reasoningLevels = reasoningLevels
    }
}
