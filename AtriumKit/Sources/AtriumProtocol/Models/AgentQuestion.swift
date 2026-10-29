import Foundation

public nonisolated struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var options: [String]
    public var allowsMultiple: Bool = false
    public var isSecret: Bool = false
    public var optionDescriptions: [String: String] = [:]

    public init(
        id: String,
        title: String,
        options: [String],
        allowsMultiple: Bool = false,
        isSecret: Bool = false,
        optionDescriptions: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.isSecret = isSecret
        self.optionDescriptions = optionDescriptions
    }
}
