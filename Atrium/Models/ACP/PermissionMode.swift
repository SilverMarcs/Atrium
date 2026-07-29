import Foundation

// Permission mode for ACP agents.
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    /// Standard behavior — prompts for dangerous operations.
    /// Claude: "default", Codex: "agent"
    case standard

    /// Auto-accept file edit operations (Claude only).
    /// Claude: "acceptEdits", Codex: falls back to "agent"
    case acceptEdits

    /// Planning mode — no actual tool execution.
    /// Claude: "plan", Codex: read-only sandbox + plan collaboration mode
    case plan

    /// Bypass all permission checks.
    /// Claude: "bypassPermissions", Codex: "agent-full-access"
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Default"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "lock.shield"
        case .acceptEdits: return "pencil.and.outline"
        case .plan: return "list.clipboard"
        case .bypassPermissions: return "bolt.shield"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Prompts for dangerous operations"
        case .acceptEdits: return "Auto-accept file edits"
        case .plan: return "Plan only, no tool execution"
        case .bypassPermissions: return "Skip all permission checks"
        }
    }

    /// The config value string to send to the Claude ACP agent.
    var claudeConfigValue: String {
        switch self {
        case .standard: return "default"
        case .acceptEdits: return "acceptEdits"
        case .plan: return "plan"
        case .bypassPermissions: return "bypassPermissions"
        }
    }

    /// The config value string to send to the Codex ACP agent.
    var codexConfigValue: String {
        CodexSessionConfiguration.agentMode(for: self)
    }

    /// Codex keeps collaboration behavior separate from its sandbox and
    /// approval mode. Plan mode must set both configuration options.
    var codexCollaborationConfigValue: String {
        CodexSessionConfiguration.collaborationMode(for: self)
    }

    /// The config value string to send to the Gemini ACP agent.
    var geminiConfigValue: String {
        switch self {
        case .standard: return "default"
        case .acceptEdits: return "autoEdit"
        case .plan: return "plan"
        case .bypassPermissions: return "yolo"
        }
    }

    /// The config value string to send to the Opencode ACP agent.
    /// Opencode exposes "build" (default primary agent) and "plan"; it
    /// has no separate accept-edits or bypass mode, so both fall back to
    /// "build".
    var opencodeConfigValue: String {
        switch self {
        case .standard: return "build"
        case .acceptEdits: return "build"
        case .plan: return "plan"
        case .bypassPermissions: return "build"
        }
    }

    func configValue(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: return claudeConfigValue
        case .codex: return codexConfigValue
        case .gemini: return geminiConfigValue
        case .opencode: return opencodeConfigValue
        }
    }
}
