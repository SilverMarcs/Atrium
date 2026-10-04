import Foundation

public struct WireSessionPatch: Codable, Sendable {
    public var title: String?
    public var date: Date?
    public var turnCount: Int?
    public var isConnecting: Bool?
    public var isActive: Bool?
    public var isProcessing: Bool?
    public var messages: [WireMessage]?
    public var modelLabel: String?
    public var permissionLabel: String?
    public var permissionSystemImage: String?
    public var usedTokens: Int?
    public var contextSize: Int?
    public var modelRawValue: String?
    public var availableModels: [WireAgentModel]?
    public var availableModes: [WirePermissionMode]?
    public var reasoningLevel: String?
    public var permissionModeRawValue: String?
    public var activeTurnToken: UUID?
    public var canSteer: Bool?
    public var questions: [QuestionPromptData]?
    public var error: String?
    public var errorChanged: Bool?

    public init(
        title: String? = nil,
        date: Date? = nil,
        turnCount: Int? = nil,
        isProcessing: Bool? = nil,
        messages: [WireMessage]? = nil,
        modelLabel: String? = nil,
        permissionLabel: String? = nil,
        permissionSystemImage: String? = nil,
        usedTokens: Int? = nil,
        contextSize: Int? = nil,
        modelRawValue: String? = nil,
        permissionModeRawValue: String? = nil,
        error: String? = nil,
        errorChanged: Bool? = nil
    ) {
        self.title = title
        self.date = date
        self.turnCount = turnCount
        self.isProcessing = isProcessing
        self.messages = messages
        self.modelLabel = modelLabel
        self.permissionLabel = permissionLabel
        self.permissionSystemImage = permissionSystemImage
        self.usedTokens = usedTokens
        self.contextSize = contextSize
        self.modelRawValue = modelRawValue
        self.permissionModeRawValue = permissionModeRawValue
        self.error = error
        self.errorChanged = errorChanged
    }
}
