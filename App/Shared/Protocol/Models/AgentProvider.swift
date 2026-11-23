import Foundation

nonisolated enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case antigravity

    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }
}
