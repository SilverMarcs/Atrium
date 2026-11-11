import Foundation

public nonisolated enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }
    public var name: String { self == .codex ? "Codex" : "Claude" }
}
