import SwiftUI

enum AgentProvider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"

    var acpPackage: String {
        switch self {
        case .claude: return "@agentclientprotocol/claude-agent-acp@latest"
        case .codex: return "@zed-industries/codex-acp@latest"
        case .gemini: return "@google/gemini-cli@latest"
        }
    }

    var acpArgs: [String] {
        switch self {
        case .claude, .codex: return []
        case .gemini: return ["--acp"]
        }
    }

    var imageName: String {
        switch self {
        case .claude: return "claude.symbols"
        case .codex: return "openai.symbols"
        case .gemini: return "gemini.symbols"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.84, green: 0.41, blue: 0.23)
        case .codex: return Color(red: 0.0, green: 0.58, blue: 0.48)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }
}
