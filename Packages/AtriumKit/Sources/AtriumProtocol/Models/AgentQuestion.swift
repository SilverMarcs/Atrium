import Foundation

public nonisolated struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var options: [String]
    public var allowsMultiple: Bool = false
    public var isSecret: Bool = false
    public var optionDescriptions: [String: String] = [:]
    /// Markdown shown under the question, such as what a secret is for and a
    /// link to where it's found.
    public var note: String?

    public init(
        id: String,
        title: String,
        options: [String],
        allowsMultiple: Bool = false,
        isSecret: Bool = false,
        optionDescriptions: [String: String] = [:],
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.isSecret = isSecret
        self.optionDescriptions = optionDescriptions
        self.note = note
    }
}
