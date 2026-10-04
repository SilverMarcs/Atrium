import Foundation

public struct WireSession: Codable, Sendable {
    public var meta: WireSessionMeta
    public var messages: [WireMessage]
    public var modelLabel: String
    public var permissionLabel: String
    public var permissionSystemImage: String
    public var usedTokens: Int
    public var contextSize: Int
    public var availableModels: [WireAgentModel]
    public var modelRawValue: String
    public var availableModes: [WirePermissionMode]
    public var permissionModeRawValue: String
    public var reasoningLevel: String
    public var activeTurnToken: UUID?
    public var canSteer: Bool
    public var questions: [QuestionPromptData]
    public var error: String?

    public init(
        meta: WireSessionMeta,
        messages: [WireMessage],
        modelLabel: String,
        permissionLabel: String,
        permissionSystemImage: String,
        usedTokens: Int,
        contextSize: Int,
        availableModels: [WireAgentModel],
        modelRawValue: String,
        availableModes: [WirePermissionMode],
        permissionModeRawValue: String,
        reasoningLevel: String = "",
        activeTurnToken: UUID? = nil,
        canSteer: Bool = false,
        questions: [QuestionPromptData] = [],
        error: String? = nil
    ) {
        self.meta = meta
        self.messages = messages
        self.modelLabel = modelLabel
        self.permissionLabel = permissionLabel
        self.permissionSystemImage = permissionSystemImage
        self.usedTokens = usedTokens
        self.contextSize = contextSize
        self.availableModels = availableModels
        self.modelRawValue = modelRawValue
        self.availableModes = availableModes
        self.permissionModeRawValue = permissionModeRawValue
        self.reasoningLevel = reasoningLevel
        self.activeTurnToken = activeTurnToken
        self.canSteer = canSteer
        self.questions = questions
        self.error = error
    }
}
