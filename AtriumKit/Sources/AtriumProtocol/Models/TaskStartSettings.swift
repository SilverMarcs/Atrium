/// Settings inherited by a blank conversation, independently of its history.
public nonisolated struct TaskStartSettings: Codable, Sendable, Equatable {
    public var model: String?
    public var reasoningEffort: String?
    public var isFastMode: Bool?

    public init(model: String? = nil, reasoningEffort: String? = nil, isFastMode: Bool? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isFastMode = isFastMode
    }
}
