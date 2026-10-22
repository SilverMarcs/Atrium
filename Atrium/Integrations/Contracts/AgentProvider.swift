enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude" }
    var settingsKey: String { "integration.\(rawValue).enabled" }
}
