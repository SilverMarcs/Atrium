import Foundation

public struct CompanionMessage: Codable, Sendable {
    public var kind: CompanionKind

    public var token: String?
    public var clientId: UUID?

    public var sessionId: UUID?

    public var promptText: String?
    public var expectedTurnToken: UUID?
    public var questionRequestId: UUID?
    public var questionAnswers: [String: [String]]?

    public var workspaceId: UUID?
    public var providerName: String?

    public var scratchpadText: String?

    public var modelRawValue: String?
    public var permissionModeRawValue: String?
    public var reasoningLevel: String?

    public var ok: Bool?

    public var error: String?

    public var serverName: String?
    public var version: Int?

    public var workspaces: [WireWorkspace]?
    public var availableProviders: [String]?

    public var session: WireSession?

    public var patch: WireSessionPatch?

    public var gitStatus: WireGitStatus?
    public var gitFiles: [WireGitFile]?
    public var gitBranch: String?
    public var gitCommitMessage: String?
    public var gitFilePath: String?
    public var gitDiffStage: String?
    public var gitDiffText: String?
    public var gitRepositoryPath: String?

    public var commands: [WireCommand]?
    public var commandId: UUID?

    public init(kind: CompanionKind) {
        self.kind = kind
    }
}
