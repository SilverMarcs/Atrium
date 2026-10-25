import Foundation

nonisolated enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude" }
}
