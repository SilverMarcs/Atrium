import Foundation

public nonisolated enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case jcode

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .jcode: "Jcode"
        }
    }
}
