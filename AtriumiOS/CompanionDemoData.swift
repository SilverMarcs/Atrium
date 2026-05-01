import Foundation

/// Mutable scratchpad for demo-mode session state. The client holds one of
/// these and `demoHandle(outgoing:)` reads/writes it instead of the
/// network. Reset on disconnect so re-entering demo starts fresh.
struct CompanionDemoState {
    /// Sessions the demo has materialised, keyed by session id. We
    /// lazy-build the message list the first time iOS subscribes so the
    /// initial workspace list stays cheap.
    var sessions: [UUID: WireSession] = [:]
    /// Pending follow-up tasks (e.g. the simulated assistant reply after a
    /// `sendPrompt`). Kept so disconnecting cancels them.
    var pendingTasks: [Task<Void, Never>] = []
}

enum CompanionDemo {
    static let providerName = "Claude"

    static let availableModels: [WireAgentModel] = [
        WireAgentModel(rawValue: "claude-opus-4-7", name: "Opus 4.7", imageName: "sparkle"),
        WireAgentModel(rawValue: "claude-sonnet-4-6", name: "Sonnet 4.6", imageName: "sparkle"),
        WireAgentModel(rawValue: "claude-haiku-4-5", name: "Haiku 4.5", imageName: "sparkle")
    ]

    static let availableModes: [WirePermissionMode] = [
        WirePermissionMode(
            rawValue: "default",
            label: "Ask",
            systemImage: "hand.raised",
            description: "Ask before running tools."
        ),
        WirePermissionMode(
            rawValue: "auto",
            label: "Auto",
            systemImage: "bolt.fill",
            description: "Run tools automatically."
        )
    ]

    static func seedWorkspaces() -> [WireWorkspace] {
        let personalId = UUID()
        let workId = UUID()
        return [
            WireWorkspace(
                id: personalId,
                name: "Personal site",
                customIconData: nil,
                isArchived: false,
                hasActiveChildProcess: false,
                scratchpad: "Ideas: dark-mode toggle, RSS feed, port blog to MDX.",
                sessions: [
                    sessionMeta(
                        in: personalId,
                        title: "Add dark mode toggle",
                        minutesAgo: 4,
                        turnCount: 6,
                        isProcessing: false,
                        hasNotification: true
                    ),
                    sessionMeta(
                        in: personalId,
                        title: "Refactor blog index",
                        minutesAgo: 38,
                        turnCount: 12,
                        isProcessing: false,
                        hasNotification: false
                    )
                ]
            ),
            WireWorkspace(
                id: workId,
                name: "Atrium",
                customIconData: nil,
                isArchived: false,
                hasActiveChildProcess: true,
                scratchpad: "Ship companion demo mode before TestFlight cut.",
                sessions: [
                    sessionMeta(
                        in: workId,
                        title: "Investigate reconnect flicker",
                        minutesAgo: 1,
                        turnCount: 3,
                        isProcessing: true,
                        hasNotification: false
                    ),
                    sessionMeta(
                        in: workId,
                        title: "App Store review notes",
                        minutesAgo: 90,
                        turnCount: 8,
                        isProcessing: false,
                        hasNotification: false
                    )
                ]
            )
        ]
    }

    static func sessionMeta(
        in workspaceId: UUID,
        title: String,
        minutesAgo: Int,
        turnCount: Int,
        isProcessing: Bool,
        hasNotification: Bool
    ) -> WireSessionMeta {
        WireSessionMeta(
            id: UUID(),
            workspaceId: workspaceId,
            title: title,
            date: Date().addingTimeInterval(-Double(minutesAgo) * 60),
            turnCount: turnCount,
            isProcessing: isProcessing,
            isArchived: false,
            providerName: providerName,
            isActive: true,
            hasNotification: hasNotification
        )
    }

    /// Builds a sample chat for the given meta. The content is the same
    /// every time — reviewers don't need variety, they need something
    /// representative to look at.
    static func sampleSession(for meta: WireSessionMeta) -> WireSession {
        let userMsg = WireMessage(
            id: UUID(),
            role: .user,
            turnIndex: 0,
            blocks: [
                WireBlock(id: UUID(), kind: .text, text: meta.title)
            ]
        )
        let assistantMsg = WireMessage(
            id: UUID(),
            role: .assistant,
            turnIndex: 1,
            blocks: [
                WireBlock(
                    id: UUID(),
                    kind: .text,
                    text: "Sure — here's a sketch of how I'd approach this:\n\n1. Read the relevant files\n2. Make the smallest change that works\n3. Verify it compiles"
                ),
                WireBlock(
                    id: UUID(),
                    kind: .toolCall,
                    text: "Read project files",
                    toolSymbolName: "doc.text.magnifyingglass"
                ),
                WireBlock(
                    id: UUID(),
                    kind: .text,
                    text: "Done. Want me to walk through any of the steps in detail?"
                )
            ]
        )
        return WireSession(
            meta: meta,
            messages: [userMsg, assistantMsg],
            modelLabel: "Opus 4.7",
            permissionLabel: "Ask",
            permissionSystemImage: "hand.raised",
            usedTokens: 14_320,
            contextSize: 200_000,
            availableModels: availableModels,
            modelRawValue: "claude-opus-4-7",
            availableModes: availableModes,
            permissionModeRawValue: "default",
            error: nil
        )
    }

    static func assistantReply(turnIndex: Int, to prompt: String) -> WireMessage {
        WireMessage(
            id: UUID(),
            role: .assistant,
            turnIndex: turnIndex,
            blocks: [
                WireBlock(
                    id: UUID(),
                    kind: .text,
                    text: "(Demo response) You said: \"\(prompt)\". In a real session this is where the agent's streaming reply would appear, with markdown, tool calls, and code blocks rendered live."
                )
            ]
        )
    }

    static func userMessage(turnIndex: Int, text: String) -> WireMessage {
        WireMessage(
            id: UUID(),
            role: .user,
            turnIndex: turnIndex,
            blocks: [WireBlock(id: UUID(), kind: .text, text: text)]
        )
    }
}
